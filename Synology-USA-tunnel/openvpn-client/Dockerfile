FROM alpine:3.20
RUN apk add --no-cache openvpn iptables iptables-legacy
COPY entrypoint.sh route-up.sh /
RUN chmod +x /entrypoint.sh /route-up.sh
ENTRYPOINT ["/entrypoint.sh"]
