FROM ruby:3.3.6-slim-bookworm AS ruby

FROM node:24-bookworm-slim

ARG TASKS_AXI_VERSION=0.2.5

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git tmux jq curl lsof procps ca-certificates python3 python3-venv less \
      build-essential pkg-config \
      libyaml-dev libffi-dev libssl-dev zlib1g-dev libgmp-dev libreadline-dev \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         -o /usr/share/keyrings/pgdg-archive-keyring.asc \
    && echo "deb [signed-by=/usr/share/keyrings/pgdg-archive-keyring.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends \
         gh postgresql-client-17 libpq-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash fm

COPY --from=ruby /usr/local /usr/local
ENV GEM_HOME=/usr/local/bundle \
    BUNDLE_APP_CONFIG=/usr/local/bundle \
    PATH=/usr/local/bundle/bin:$PATH
RUN chown -R fm:fm /usr/local/bundle

RUN npm install -g \
      @anthropic-ai/claude-code \
      @hauptsache.net/clickup-mcp \
      tasks-axi@${TASKS_AXI_VERSION} \
      quota-axi gh-axi lavish-axi chrome-devtools-axi \
    && npm cache clean --force

# UV_TOOL_DIR keeps the tool payload out of /root, which the unprivileged
# runtime user cannot traverse; without it the bin symlink resolves to nothing.
ENV UV_INSTALL_DIR=/usr/local/bin \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_TOOL_DIR=/opt/uv-tools
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && uv tool install mcp-server-motherduck \
    && chmod -R a+rX /opt/uv-tools

COPY bin/fm-install-treehouse.sh /tmp/fm-install-treehouse.sh
RUN /tmp/fm-install-treehouse.sh /usr/local/bin && rm -f /tmp/fm-install-treehouse.sh

# The installer ends by starting a daemon, which cannot work in a build layer
# with no init and no running services. That step is expected to fail here; the
# install itself is what matters, so assert the binary landed before moving on.
RUN HOME=/home/fm sh -c 'curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh' \
      || echo 'no-mistakes: daemon start skipped at build time'; \
    test -x /home/fm/.no-mistakes/bin/no-mistakes \
    && ln -sf /home/fm/.no-mistakes/bin/no-mistakes /usr/local/bin/no-mistakes \
    && chown -R fm:fm /home/fm/.no-mistakes

COPY --chown=fm:fm . /opt/firstmate
COPY --chown=fm:fm docker/entrypoint.sh /usr/local/bin/fm-entrypoint.sh
RUN chmod +x /usr/local/bin/fm-entrypoint.sh

USER fm
WORKDIR /opt/firstmate

ENV FM_HOME=/home/fm/fmhome \
    CLAUDE_CONFIG_DIR=/home/fm/.claude \
    XDG_STATE_HOME=/home/fm/.local/state \
    TERM=xterm-256color

ENTRYPOINT ["/usr/local/bin/fm-entrypoint.sh"]
CMD ["sleep", "infinity"]
