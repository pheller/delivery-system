# Copyright 2022, Phillip Heller
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

import Config

config :portal,
  namespace: Prodigy.Portal,
  ecto_repos: [Prodigy.Core.Data.Repo],
  generators: [context_app: false]

# Configures the endpoint
config :portal, Prodigy.Portal.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: Prodigy.Portal.ErrorHTML, json: Prodigy.Portal.ErrorJSON],
    layout: false
  ],
  pubsub_server: Prodigy.Portal.PubSub,
  live_view: [signing_salt: "oxOjAYBY"],
  server: true

config :portal, Prodigy.Portal.UserManager.Guardian,
  issuer: "prodigy_portal",
  secret_key: "r6ygfUoemC9s6HPcZYwm9EGAC/+Xt6NmcvAidvW7wN2Yd2k3TpuetRZTB5Juvvy0"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/portal/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.3.3",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/portal/assets", __DIR__)
  ]

config :server,
  ecto_repos: [Prodigy.Core.Data.Repo],
  auth_timeout: 60 * 1000

config :server, Prodigy.Server.Scheduler,
  jobs: [
    expunge_job: [
      schedule: "@daily",
      task: {Prodigy.Server.Service.Messaging, :expunge, []}
    ]
  ]

config :core, ecto_repos: [Prodigy.Core.Data.Repo], ecto_adapter: Ecto.Adapters.Postgres

config :logger, :console, format: "$time $metadata[$level] $message\n"
config :logger, level: :info

import_config "#{Mix.env()}.exs"
