FROM valkey/valkey-bundle:9.1.0

LABEL maintainer="Peter Vogel <vogel.peter@gmail.com>"
# Only two runtime deps are actually used by docker-entrypoint.sh:
#   - gettext-base -> envsubst (renders the .tmpl config files)
#   - supervisor   -> supervisord (runs the valkey-server processes)
# ruby/rubygems were only for the legacy valkey-trib.rb cluster builder
# (valkey < 5.0); 9.x uses "valkey-cli --cluster create". The build toolchain
# (gcc/make/build-essential/tcl/...) is unneeded because valkey-bundle ships
# prebuilt binaries + modules. NOTE: "rubygems" is not a Debian package, which
# is what made "apt-get install" fail with exit code 100.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -yqq \
      supervisor gettext-base && \
    apt-get clean -yqq && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /valkey-conf && mkdir /valkey-data

COPY valkey-cluster.tmpl /valkey-conf/valkey-cluster.tmpl
COPY valkey.tmpl         /valkey-conf/valkey.tmpl
COPY sentinel.tmpl      /valkey-conf/sentinel.tmpl
COPY LICENSE /LICENSE

# Add startup script
COPY docker-entrypoint.sh /docker-entrypoint.sh

# Add script that generates supervisor conf file based on environment variables
COPY generate-supervisor-conf.sh /generate-supervisor-conf.sh

RUN chmod 755 /docker-entrypoint.sh

EXPOSE 7000 7001 7002 7003 7004 7005 7006 7007 5000 5001 5002

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["valkey-cluster"]
