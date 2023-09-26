defmodule Prodigy.Portal.UsersLive do
  use Prodigy.Portal, :live_view

  alias Prodigy.Portal.Models.Users


  def mount(_params, _session, socket) do
    users = Users.list_users()
    users_online = Users.list_online_users()

    socket = assign(socket, page_title: "Service Users Online", users: users, users_online: users_online)
    {:ok, socket}
  end

  def handle_params(unsigned_params, uri, socket) do
    # TODO will need some pubsub linkage to trigger a refresh on a db change
    # PubSub.subscribe("session_changes")
    # and, on the Server, we'll do PubSub.broadcast_from!(self(), "session_changes", ?, ?)
    # then,here, we'll override handle_info that will call send_update/2

    {:noreply, socket}
  end
end