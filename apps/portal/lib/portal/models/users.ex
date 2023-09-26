defmodule Prodigy.Portal.Models.Users do

  # TODO move this into Prodigy.Core
  alias Prodigy.Core.Data.Service.User, as: ServiceUser
  alias Prodigy.Core.Data.Repo

  import Ecto.Query

  def list_users() do
    query = ServiceUser |> order_by(desc: :id)
    Repo.all(query)
  end

  def list_online_users() do
    query = ServiceUser
            |> where(logged_on: true)
            |> order_by(desc: :id)
    Repo.all(query)
  end
end