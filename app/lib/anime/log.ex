defmodule Anime.Log do
  @moduledoc """
  Application log events use fixed messages and a typed field allowlist. Never
  pass exception text, params, headers, changesets or job args as log messages.
  Unstructured dependency messages are intentionally not rendered verbatim.
  """
  require Logger

  @messages %{
    http_response: "HTTP request completed",
    application_started: "Application started",
    application_stopped: "Application stopped",
    live_mounted: "LiveView mounted",
    live_params: "LiveView parameters handled",
    live_event: "LiveView event handled",
    live_failed: "LiveView callback failed",
    job_started: "Oban job started",
    job_completed: "Oban job completed",
    job_cancelled: "Oban job cancelled",
    job_snoozed: "Oban job snoozed",
    job_retry: "Oban job will retry",
    job_failed: "Oban job exhausted or discarded",
    mail_accepted: "Mail transport accepted message",
    mail_failed: "Mail transport failed",
    queue_started: "Oban queue started",
    queue_stopped: "Oban queue stopped",
    queue_failed: "Oban queue process failed",
    telemetry_failed: "Log telemetry projection failed safely",
    async_failed: "Asynchronous callback failed",
    access_denied: "Access denied",
    rate_limited: "Rate limit reached",
    permissions_cache_reset: "Role permissions ETS cache reset",
    proxy_untrusted_peer: "Discarded X-Forwarded-For (untrusted_peer)",
    proxy_invalid: "Discarded X-Forwarded-For (invalid)",
    proxy_too_many: "Discarded X-Forwarded-For (too_many)",
    proxy_all_trusted: "Discarded X-Forwarded-For (all_trusted)"
  }

  def message(event), do: Map.get(@messages, event)

  def emit(event, fields \\ %{}) when is_map(fields) do
    message = message(event) || raise ArgumentError, "Unknown application log event"

    level =
      case event do
        :http_response ->
          http_level(fields[:status])

        e
        when e in [
               :live_failed,
               :job_failed,
               :telemetry_failed,
               :async_failed,
               :mail_failed,
               :queue_failed
             ] ->
          :error

        e when e in [:live_mounted, :live_params, :live_event, :job_started, :mail_accepted] ->
          :debug

        e
        when e in [
               :application_started,
               :application_stopped,
               :job_completed,
               :job_cancelled,
               :job_snoozed,
               :permissions_cache_reset,
               :queue_started,
               :queue_stopped
             ] ->
          :info

        _ ->
          :warning
      end

    # Sanitize before Logger too: other in-process handlers must not receive
    # secrets accidentally passed as fields to this API.
    fields = Anime.LogFormatter.fields(fields, level)
    Logger.bare_log(level, message, anime_event: event, anime_fields: fields)
  end

  def proxy_rejected(reason) do
    event =
      %{
        untrusted_peer: :proxy_untrusted_peer,
        invalid: :proxy_invalid,
        too_many: :proxy_too_many,
        all_trusted: :proxy_all_trusted
      }
      |> Map.fetch!(reason)

    emit(event)
  end

  def http_level(status) when status in 100..399, do: :info
  def http_level(status) when status in 400..499, do: :warning
  def http_level(_), do: :error

  def safe_path(path, method \\ "GET")

  def safe_path(path, method) when is_binary(path) and byte_size(path) <= 8192 do
    path = path |> String.split("?", parts: 2) |> hd()

    cond do
      String.starts_with?(path, "/assets/") ->
        "/assets/*path"

      String.starts_with?(path, "/images/") ->
        "/images/*path"

      path == "/favicon.ico" ->
        path

      true ->
        case Phoenix.Router.route_info(AnimeWeb.Router, method, path, "localhost") do
          %{route: "/*path"} -> "/[unmatched]"
          %{route: "/dev/mailbox"} -> "/dev/mailbox/*path"
          %{route: route} -> route
          _ -> "/[unmatched]"
        end
    end
  rescue
    _ -> "/[unmatched]"
  catch
    _, _ -> "/[unmatched]"
  end

  def safe_path(_, _), do: "/[unmatched]"
end
