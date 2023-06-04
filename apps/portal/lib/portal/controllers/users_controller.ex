defmodule Prodigy.Portal.UsersController do
  use Prodigy.Portal, :controller

  alias Prodigy.Portal.Models.Users

  def index(conn, _pars) do
    users = Users.list_users()
    users_online = Users.list_online_users()
    render(conn, :index, users: users, users_online: users_online)
  end
end