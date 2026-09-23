# Copyright 2026, Phillip Heller
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

defmodule Prodigy.Core.Data.Repo.Migrations.AddSandboxToUser do
  use Ecto.Migration

  # Operator-only state, not a profile TAC: the client never reads it and
  # there is no authentic Prodigy concept for a demo mode. Shaped like
  # `concurrency_limit` and `date_deleted` - plain columns on `user`.
  #
  # A sandboxed session has its service dispatch wrapped in a transaction
  # that always rolls back, so nothing the user does persists. See
  # Prodigy.Server.Router.
  def change do
    alter table(:user) do
      add :sandbox, :boolean, null: false, default: false
    end

    # Already-deployed environments have DEMO99A from a prior seed run; a
    # fresh DB creates it after migrations, so seed.sh passes --sandbox.
    execute(
      "update \"user\" set sandbox = true where id = 'DEMO99A'",
      "update \"user\" set sandbox = false where id = 'DEMO99A'"
    )
  end
end
