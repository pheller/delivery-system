defmodule Prodigy.Core.Data.Repo.Migrations.AddPortalUser do
  use Ecto.Migration

  def change do
    create table(:portal_user) do
      add :username, :string
      add :password_hashed, :string

      add :provider, :string
      add :provider_uid, :integer

      timestamps()
    end
  end
end
