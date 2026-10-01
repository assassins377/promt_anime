defmodule AnimeWeb do
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      import Plug.Conn
      use Gettext, backend: AnimeWeb.Gettext
    end
  end

  def html do
    quote do
      use Phoenix.Component
      use Gettext, backend: AnimeWeb.Gettext
      import Phoenix.HTML
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {AnimeWeb.Layouts, :app}, log: false
      use Gettext, backend: AnimeWeb.Gettext
      import AnimeWeb.Components
    end
  end

  defmacro __using__(which), do: apply(__MODULE__, which, [])
end
