defmodule Prodigy.Portal.Models.Users do

  # TODO move this into Prodigy.Core
  alias Prodigy.Core.Data.User
  alias Prodigy.Core.Data.Repo

  import Ecto.Query

  def list_users() do
    query = User |> order_by(desc: :id)
    Repo.all(query)
  end

  def list_online_users() do
    query = User
            |> where(logged_on: true)
            |> order_by(desc: :id)
    Repo.all(query)
  end
end