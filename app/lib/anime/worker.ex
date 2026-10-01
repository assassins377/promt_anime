defmodule Anime.Worker do
  @moduledoc "Oban workers persist the enqueuer's correlation in meta, not args."
  defmacro __using__(opts) do
    quote do
      use Oban.Worker, unquote(opts)
      @impl Oban.Worker
      def new(args, opts) do
        super(args, Anime.LogContext.job_options(__MODULE__, opts))
      end
    end
  end
end
