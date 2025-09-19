defmodule Prodigy.Core.Data.Repo.Migrations.CreateBulletinBoards do
  use Ecto.Migration

  def change do
    # Create clubs table
    create table(:club) do
      add :handle, :string, size: 3, null: false
      add :name, :string, null: false

      timestamps()
    end

    create unique_index(:club, [:handle])

    # Create topics table with smallint id
    create table(:topic, primary_key: false) do
      add :id, :smallserial, primary_key: true
      add :club_id, references(:club, on_delete: :restrict), null: false
      add :title, :string, null: false
      add :closed, :boolean, default: false, null: false

      timestamps()
    end

    create index(:topic, [:club_id])

    # Create posts table
    create table(:post) do
      add :topic_id, references(:topic, type: :smallint, on_delete: :restrict), null: false
      add :sent_date, :utc_datetime, null: false
      add :in_reply_to, references(:post, on_delete: :restrict), null: true
      add :to_name, :string, default: ""
      add :from_id, :string, null: false  # References user.id but not enforced at DB level
      add :subject, :string, null: false
      add :body, :text, null: false

      timestamps()
    end

    create index(:post, [:topic_id])
    create index(:post, [:in_reply_to])
    create index(:post, [:from_id])
    create index(:post, [:sent_date])

    # Index for efficiently finding replies to a post
    create index(:post, [:in_reply_to, :sent_date])
    end
end
