FROM ubuntu:latest 
RUN apt update
RUN apt install python3 python3-venv -y
RUN mkdir /opt/server
WORKDIR /opt/server
RUN python3 -m venv .venv
COPY requirements.txt .
RUN .venv/bin/pip install --no-cache-dir -r requirements.txt
RUN mkdir Sync
COPY Sync ./Sync/
COPY docker-entrypoint.sh .
RUN chmod +x docker-entrypoint.sh
EXPOSE 8000
CMD ["/opt/server/docker-entrypoint.sh"]