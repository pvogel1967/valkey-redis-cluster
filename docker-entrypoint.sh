#!/bin/sh

if [ "$1" = 'valkey-cluster' ]; then
    # Allow passing in cluster IP by argument or environmental variable
    IP="${2:-$IP}"

    if [ -z "$IP" ]; then # If IP is unset then discover it
        IP=$(hostname -I)
    fi

    echo " -- IP Before trim: '$IP'"
    IP=$(echo ${IP}) # trim whitespaces
    echo " -- IP Before split: '$IP'"
    IP=${IP%% *} # use the first ip
    echo " -- IP After trim: '$IP'"

    if [ -z "$INITIAL_PORT" ]; then # Default to port 7000
      INITIAL_PORT=7000
    fi

    if [ -z "$MASTERS" ]; then # Default to 3 masters
      MASTERS=3
    fi

    if [ -z "$SLAVES_PER_MASTER" ]; then # Default to 1 slave for each master
      SLAVES_PER_MASTER=1
    fi

    if [ -z "$BIND_ADDRESS" ]; then # Default to any IPv4 address
      BIND_ADDRESS=0.0.0.0
    fi

    max_port=$(($INITIAL_PORT + $MASTERS * ( $SLAVES_PER_MASTER  + 1 ) - 1))
    first_standalone=$(($max_port + 1))
    if [ "$STANDALONE" = "true" ]; then
      STANDALONE=2
    fi
    if [ ! -z "$STANDALONE" ]; then
      max_port=$(($max_port + $STANDALONE))
    fi

    # Detect whether the cluster was already initialised on a previous run.
    # valkey writes nodes.conf once the cluster is created, so its presence
    # means we are restarting an existing cluster: we must NOT wipe state or
    # re-run "cluster create", otherwise nodes come back with keys but no slot
    # assignments and "create" aborts with "Node ... is not empty".
    if [ -f "/valkey-data/${INITIAL_PORT}/nodes.conf" ]; then
      CLUSTER_EXISTS=true
    else
      CLUSTER_EXISTS=false
    fi

    for port in $(seq $INITIAL_PORT $max_port); do
      mkdir -p /valkey-conf/${port}
      mkdir -p /valkey-data/${port}

      # Only on a fresh start: remove stale persistence so "cluster create"
      # sees empty nodes. NOTE: valkey >=7 stores a multi-part AOF in
      # appendonlydir/ (e.g. appendonly.aof.1.incr.aof), so the old single
      # "appendonly.aof" cleanup was a no-op and left keys behind on restart.
      if [ "$CLUSTER_EXISTS" = "false" ]; then
        rm -f  /valkey-data/${port}/nodes.conf
        rm -f  /valkey-data/${port}/dump.rdb
        rm -f  /valkey-data/${port}/appendonly.aof
        rm -rf /valkey-data/${port}/appendonlydir
      fi

      if [ "$port" -lt "$first_standalone" ]; then
        PORT=${port} BIND_ADDRESS=${BIND_ADDRESS} envsubst < /valkey-conf/valkey-cluster.tmpl > /valkey-conf/${port}/valkey.conf
        nodes="$nodes $IP:$port"
      else
        PORT=${port} BIND_ADDRESS=${BIND_ADDRESS} envsubst < /valkey-conf/valkey.tmpl > /valkey-conf/${port}/valkey.conf
      fi

      if [ "$port" -lt $(($INITIAL_PORT + $MASTERS)) ]; then
        if [ "$SENTINEL" = "true" ]; then
          PORT=${port} SENTINEL_PORT=$((port - 2000)) envsubst < /valkey-conf/sentinel.tmpl > /valkey-conf/sentinel-${port}.conf
          cat /valkey-conf/sentinel-${port}.conf
        fi
      fi

    done

    bash /generate-supervisor-conf.sh $INITIAL_PORT $max_port > /etc/supervisor/supervisord.conf

    supervisord -c /etc/supervisor/supervisord.conf
    sleep 3

    if [ "$CLUSTER_EXISTS" = "true" ]; then
      echo "Existing cluster detected (nodes.conf present) -- skipping 'cluster create'."
      echo "Nodes will rejoin from their persisted nodes.conf."
    else
      #
      ## Check the version of valkey-cli and if we run on a valkey server below 5.0
      ## If it is below 5.0 then we use the valkey-trib.rb to build the cluster
      #
      /usr/local/bin/valkey-cli --version | grep -E "valkey-cli 3.0|valkey-cli 3.2|valkey-cli 4.0"

      echo "Using valkey-cli to create the cluster"
      echo "yes" | eval valkey-cli --cluster create --cluster-replicas "$SLAVES_PER_MASTER" "$nodes"
    fi

    if [ "$SENTINEL" = "true" ]; then
      for port in $(seq $INITIAL_PORT $(($INITIAL_PORT + $MASTERS))); do
        valkey-sentinel /valkey-conf/sentinel-${port}.conf &
      done
    fi

    tail -f /var/log/supervisor/valkey*.log
else
  exec "$@"
fi
