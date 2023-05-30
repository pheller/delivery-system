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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :portal, Prodigy.Portal.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "iVDT09ynvP5ZjrhiDGoDessLMIH4RzYKMo3t2R9xvxZsJr0I4+BMgrmIZ5jQ3llj",
  server: false

config :core, Prodigy.Core.Data.Repo,
  database: "prodigytest",
  username: "prodigytest",
  password: "prodigytest",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox

config :server,
  auth_timeout: 3000

config :logger, level: :info
