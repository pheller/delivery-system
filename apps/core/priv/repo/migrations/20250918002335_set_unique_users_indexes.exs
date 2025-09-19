defmodule Prodigy.Core.Data.Repo.Migrations.SetUniqueUsersIndexes do
  use Ecto.Migration

  def change do
    create unique_index(:portal_user, [:username])
    create unique_index(:portal_user, [:provider_uid])
  end
end
