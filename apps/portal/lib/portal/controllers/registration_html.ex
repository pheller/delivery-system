defmodule Prodigy.Portal.RegistrationHTML do
  use Prodigy.Portal, :html

  def new(assigns) do
    ~H"""
    <div class="max-w-md m-20">
      <header class="font-bold">Register a new account</header>

      <.simple_form for={@form} action={~p"/register"}>
        <.input field={@form[:username]} label="Username" />
        <.input field={@form[:password]} label="Password" type="password" id="password-input" />
        <span class="italic">don't lose this!</span>
        <div class="flex flex-row gap-2">
          <.input
            type="checkbox"
            autocomplete="off"
            name="password-visibility"
            phx-click={JS.toggle_attribute({"type", "password", "text"}, to: "#password-input")}
          />
          <.icon name="hero-eye" />
        </div>

        <:actions>
          <.button>Create Account</.button>
        </:actions>
      </.simple_form>

      <div class="my-16">
        <span>Already have an account?</span>
        <.button_link href="/login">Login instead</.button_link>
      </div>
    </div>
    """
  end
end
