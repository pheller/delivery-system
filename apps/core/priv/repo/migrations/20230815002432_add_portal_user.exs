defmodule Prodigy.Core.Data.Repo.Migrations.AddPortalUser do
  use Ecto.Migration

  def change do
    create table(:portal_user, primary_key: false) do
      add :username, :string, primary_key: true
      add :password, :string
    end
  end
end
