defmodule Prodigy.Portal.EnrollmentHTML do
  use Prodigy.Portal, :html

  def new(assigns) do
    ~H"""
    <h2>Get Started</h2>

    <div class="flex flex-col justify-center items-center gap-4">
      <div class="font-semibold text-xl m-10">
        Sign up for Prodigy Reloaded by signing in with one of the following
        service providers. Pick one, then click it's icon to get started.
      </div>

      <div>
        <.button>
          <.link href="/auth/github">Github</.link>
        </.button>
      </div>
    </div>
    """
  end
end
