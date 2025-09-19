defmodule Prodigy.Portal.GetStartedLive do
  use Prodigy.Portal, :live_view

  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Get Started")
    {:ok, socket}
  end

  def handle_params(_unsigned_params, _uri, socket) do
    {:noreply, socket}
  end
end
