defmodule Prodigy.Core.Data.Repo.Migrations.CreateUserClub do
  use Ecto.Migration

  def change do
    create table(:user_club, primary_key: false) do
      add :user_id, references(:user, type: :string, on_delete: :delete_all), primary_key: true, null: false
      add :club_id, references(:club, on_delete: :delete_all), primary_key: true, null: false
      add :last_read_date, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:user_club, [:user_id, :club_id])
    create index(:user_club, [:club_id])
    create index(:user_club, [:last_read_date])
  end
end
