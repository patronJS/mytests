FROM alpine:3.20
RUN apk add --no-cache openvpn iptables iptables-legacy
COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
