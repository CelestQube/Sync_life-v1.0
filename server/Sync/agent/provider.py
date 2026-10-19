"""HTTP adapters for Bailian and optional local Ollama. Never log model payloads/keys."""
import json
import re
from urllib.parse import urlparse

import requests
from django.conf import settings


class ModelError(Exception):
    def __init__(self, message, code='model_unavailable', status=503):
        super().__init__(message)
        self.code = code
        self.status = status


def configuration_status():
    local = settings.AGENT_PROVIDER == 'ollama'
    return {'provider': settings.AGENT_PROVIDER, 'model': settings.AGENT_MODEL,
            'configured': bool(settings.AGENT_MODEL and (local or settings.AGENT_API_KEY))}


def complete(messages, *, structured=False):
    if not configuration_status()['configured']:
        raise ModelError('尚未配置百炼 API 密钥，请在后端 server/.env 设置 DASHSCOPE_API_KEY 后重启服务。', 'model_not_configured')
    parsed = urlparse(settings.AGENT_API_BASE_URL)
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1', '::1')):
        raise ModelError('模型服务地址需要 HTTPS；本机调试可使用 localhost。', 'invalid_configuration')
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ModelError('模型基础地址格式不正确。', 'invalid_configuration')
    local = settings.AGENT_PROVIDER == 'ollama'
    if settings.AGENT_PROVIDER not in ('bailian', 'compatible', 'ollama'):
        raise ModelError('不支持的模型服务类型。', 'invalid_configuration')
    payload = {'model': settings.AGENT_MODEL, 'messages': messages, 'stream': False}
    headers = {'Content-Type': 'application/json'}
    if local:
        endpoint = '/api/chat'
        payload['options'] = {'temperature': 0.3, 'num_predict': 4096 if structured else 2000}
        if structured:
            payload['format'] = 'json'
    else:
        endpoint = '/chat/completions'
        headers['Authorization'] = f'Bearer {settings.AGENT_API_KEY}'
        payload.update(temperature=0.3, max_tokens=4096 if structured else 2000)
        if settings.AGENT_PROVIDER == 'bailian':
            payload['enable_thinking'] = False
        if structured:
            payload['response_format'] = {'type': 'json_object'}
    try:
        # Streaming transport bounds response memory even though generation itself is non-streaming.
        with requests.post(settings.AGENT_API_BASE_URL.rstrip('/') + endpoint, json=payload,
                           headers=headers, timeout=(5, settings.AGENT_MODEL_TIMEOUT),
                           allow_redirects=False, stream=True) as response:
            if response.status_code in (401, 403):
                raise ModelError('模型服务鉴权失败，请检查后端密钥、地域和模型权限。', 'model_authentication')
            if response.status_code == 429:
                raise ModelError('模型服务额度不足或请求过于频繁，请稍后重试。', 'model_rate_limit', 429)
            if response.status_code != 200:
                raise ModelError('模型服务调用失败，请检查模型名称、接入地址或稍后重试。')
            raw = bytearray()
            for chunk in response.iter_content(8192):
                raw.extend(chunk)
                if len(raw) > 256 * 1024:
                    raise ModelError('模型返回内容过长，请缩小问题范围。', 'invalid_model_output', 502)
            result = json.loads(raw)
        content = result['message']['content'] if local else result['choices'][0]['message']['content']
        if not isinstance(content, str):
            raise ValueError()
        content = re.sub(r'<think>.*?</think>', '', content, flags=re.S).strip()
        if not content or len(content) > 20000 or '<think>' in content:
            raise ValueError()
        return content
    except ModelError:
        raise
    except requests.Timeout:
        raise ModelError('模型响应超时，可使用同一条消息重试。', 'model_timeout', 504) from None
    except requests.RequestException:
        raise ModelError('暂时无法连接模型服务，请稍后重试。') from None
    except (ValueError, KeyError, IndexError, TypeError):
        raise ModelError('模型未返回有效答案，请重试。', 'invalid_model_output', 502) from None
