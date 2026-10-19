"""Tencent WebService adapter. Keys and precise coordinates stay server-side."""
import hashlib
import math

import requests
from django.conf import settings

from .provider import ModelError


PROVIDER = 'tencent'
RADIUS_METERS = 5000


def _coordinate(latitude, longitude):
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
           for value in (latitude, longitude)):
        raise ValueError('查询附近餐馆需要有效定位')
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        raise ValueError('经纬度超出范围')
    return latitude, longitude


def _get(path, params):
    params = {**params, 'key': settings.TENCENT_MAP_KEY, 'output': 'json'}
    if settings.TENCENT_MAP_SECRET_KEY:
        # Sign sorted ORIGINAL values, before requests URL-encodes them.
        query = '&'.join(f'{key}={value}' for key, value in sorted(params.items()))
        params['sig'] = hashlib.md5((path + '?' + query + settings.TENCENT_MAP_SECRET_KEY).encode('utf-8')).hexdigest()
    with requests.get('https://apis.map.qq.com' + path, params=params,
                      timeout=(3, 8), allow_redirects=False) as response:
        response.raise_for_status()
        data = response.json()
    if not isinstance(data, dict):
        raise ValueError('Invalid map response')
    status = data.get('status')
    if type(status) is not int:
        raise ValueError('Invalid map status')
    if status != 0:
        # Never relay raw provider errors/URLs: they may contain keys or location.
        if status == 111:
            raise ModelError('地图服务签名校验失败，请检查后端的腾讯 SecretKey 配置。', 'places_signature_error')
        if status in (110, 112, 113, 190, 199, 301, 311):
            raise ModelError('地图服务未授权，请检查腾讯 Key、WebServiceAPI 权限和授权 IP。', 'places_authorization_error')
        if status in (120, 121):
            raise ModelError('地图查询额度或频率已达上限，请稍后再试。', 'places_quota_exceeded')
        raise ValueError('Map query failed')
    return data


def _distance(item, origin):
    value = item.get('_distance')
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
        return float(value)
    # Some responses omit _distance. Derive straight-line distance from returned POI coordinates.
    location = item.get('location')
    if not isinstance(location, dict):
        return None
    try:
        latitude, longitude = _coordinate(location.get('lat'), location.get('lng'))
    except ValueError:
        return None
    left, right = math.radians(origin[0]), math.radians(latitude)
    delta_lat = right - left
    delta_lon = math.radians(longitude - origin[1])
    arc = math.sin(delta_lat / 2) ** 2 + math.cos(left) * math.cos(right) * math.sin(delta_lon / 2) ** 2
    return 6371000 * 2 * math.asin(math.sqrt(min(1., max(0., arc))))


def nearby_restaurants(latitude, longitude, queries):
    if not settings.TENCENT_MAP_KEY:
        raise ModelError('餐馆查询暂未启用，可先询问饮食搭配建议。', 'places_not_configured')
    _coordinate(latitude, longitude)
    try:
        # Android Geolocator supplies GPS/WGS84. Tencent uses lat,lng order in both APIs.
        point = _get('/ws/coord/v1/translate', {'locations': f'{latitude:.6f},{longitude:.6f}', 'type': 1})
        locations = point.get('locations')
        if not isinstance(locations, list) or len(locations) != 1 or not isinstance(locations[0], dict):
            raise ValueError('Invalid converted location')
        origin = _coordinate(locations[0].get('lat'), locations[0].get('lng'))
        boundary = f'nearby({origin[0]:.6f},{origin[1]:.6f},{RADIUS_METERS},0)'
        places = {}
        # One keyword per request; do not assume Amap's | syntax works here.
        for query in queries[:3]:
            keyword, category = query.get('keyword', ''), query.get('category', '')
            data = _get('/ws/place/v1/search', {'boundary': boundary, 'keyword': keyword or '美食',
                'filter': 'category=' + (category or '美食'), 'orderby': '_distance', 'page_size': 20, 'page_index': 1})
            if not isinstance(data.get('data'), list):
                raise ValueError('Invalid place list')
            for item in data['data'][:20]:
                if not isinstance(item, dict) or not isinstance(item.get('title'), str) or not item['title'].strip():
                    continue
                distance = _distance(item, origin)
                if distance is None or distance > RADIUS_METERS:
                    continue
                name = item['title'].strip()[:200]
                address = item['address'][:300] if isinstance(item.get('address'), str) else ''
                identity = ('id', str(item['id'])) if item.get('id') else ('address', name, address)
                related = not bool(keyword)
                priority = (related, distance)
                if identity not in places or priority < places[identity][0]:
                    poi_category = item.get('category', '')
                    poi_category = poi_category[:100] if isinstance(poi_category, str) else ''
                    label = category or keyword
                    intro = f'地图标注：{poi_category.replace(":", " / ")}。' if poi_category else '地图未提供详细分类。'
                    intro += f'相近类型「{label}」参考，具体菜品请向商家确认。' if related else f'由地图按「{label}」检索到，具体菜品请向商家确认。'
                    places[identity] = (priority, {'name': name, 'address': address, 'distance_m': str(round(distance)),
                        'category': poi_category, 'description': intro, 'matched_query': label, 'related_match': related})
        return [row[1] for row in sorted(places.values(), key=lambda row: row[0])[:5]]
    except (requests.RequestException, ValueError, TypeError, KeyError, OverflowError):
        raise ModelError('腾讯地图查询失败，请检查服务配置或稍后重试。', 'places_unavailable') from None
