FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Seoul

RUN printf 'Acquire::Retries "10";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\nAcquire::Queue-Mode "access";\n' >/etc/apt/apt.conf.d/80-retries && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      apt-utils debconf locales tzdata ca-certificates && \
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-server sudo passwd \
      curl wget git vim nano tmux htop tree less rsync unzip zip jq file \
      bash-completion procps psmisc lsof net-tools iproute2 iputils-ping dnsutils \
      python3 python3-pip python3-venv python3-dev \
      build-essential gcc g++ make cmake pkg-config gdb \
      software-properties-common apt-transport-https && \
    mkdir -p /var/run/sshd /persist/ssh /persist/auth /workspace && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1001 admin && \
    groupadd -g 1002 ysadmin && \
    groupadd -g 1003 engadmin && \
    useradd -m -u 1001 -g 1002 -G admin -s /bin/bash ysadmin && \
    useradd -m -u 1002 -g 1003 -G admin -s /bin/bash engadmin && \
    echo 'ysadmin ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-ysadmin && \
    echo '%admin ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/91-admin && \
    chmod 440 /etc/sudoers.d/90-ysadmin /etc/sudoers.d/91-admin

RUN sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -ri 's@^#?AuthorizedKeysFile .*@AuthorizedKeysFile .ssh/authorized_keys@' /etc/ssh/sshd_config && \
    sed -ri 's/^#?UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config && \
    printf '\nAllowUsers ysadmin engadmin engcluster*\n' >> /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
COPY sync-auth-db.sh /usr/local/sbin/sync-auth-db
COPY passwd-wrapper.sh /usr/local/bin/passwd

RUN chmod +x /entrypoint.sh /usr/local/sbin/sync-auth-db /usr/local/bin/passwd

EXPOSE 22 2201 2202 2203 2204 2205

CMD ["/entrypoint.sh"]
