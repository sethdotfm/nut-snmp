FROM alpine:3.24

# The nut package is built --with-snmp, so snmp-ups ships in the main package.
# hidapi/eudev come along as hard dependencies; there is no SNMP-only subpackage.
RUN apk add --no-cache nut

# The package ships sample ups.conf/upsd.conf/upsd.users into /etc/nut. They
# have to go: the entrypoint treats "this file exists" as "the operator mounted
# it" and leaves it alone, so leaving the samples in place would silently run
# the container on NUT's examples -- an upsd.conf that is pure comments, which
# means no LISTEN directive and no users, and nothing can ever connect.
RUN rm -rf /etc/nut/* && mkdir -p /etc/nut

# Fail the build loudly if Alpine ever relocates these, or starts shipping
# configs again, rather than at runtime.
RUN set -eux; \
    test -x /usr/lib/nut/snmp-ups; \
    command -v upsd; \
    command -v upsc; \
    id nut; \
    test -z "$(ls -A /etc/nut)"

COPY lib/render-config.sh /usr/local/lib/nut-snmp/render-config.sh
COPY healthcheck.sh /usr/local/bin/nut-snmp-healthcheck
COPY entrypoint.sh /usr/local/bin/nut-snmp-entrypoint
RUN chmod 0755 /usr/local/lib/nut-snmp/render-config.sh \
                /usr/local/bin/nut-snmp-healthcheck \
                /usr/local/bin/nut-snmp-entrypoint

EXPOSE 3493

# Role-aware: on the server this proves upsd answers AND every driver is
# publishing fresh data; on a driver it proves the state socket exists.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/nut-snmp-healthcheck"]

ENTRYPOINT ["/usr/local/bin/nut-snmp-entrypoint"]
CMD ["server"]

LABEL org.opencontainers.image.title="nut-snmp" \
      org.opencontainers.image.description="SNMP-only Network UPS Tools server: snmp-ups driver and upsd as separate foreground processes." \
      org.opencontainers.image.licenses="Unlicense"
