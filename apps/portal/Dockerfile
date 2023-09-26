FROM elixir:1.13.4-otp-25-slim AS release_stage

RUN apt-get update
RUN apt-get install --yes build-essential inotify-tools postgresql-client
RUN mix local.hex --force
RUN mix local.rebar --force

COPY apps/core/mix.exs apps/core/mix.exs
COPY apps/portal/mix.exs apps/portal/mix.exs

COPY mix.exs mix.lock ./

ENV MIX_ENV=prod

RUN mix deps.get
RUN mix deps.compile

COPY apps/core apps/core
COPY apps/portal apps/portal

COPY config config

RUN mix release portal

FROM elixir:1.13.4-otp-25-slim AS run_stage

COPY --from=release_stage $HOME/_build .
CMD ["./prod/rel/portal/bin/portal", "start"]
