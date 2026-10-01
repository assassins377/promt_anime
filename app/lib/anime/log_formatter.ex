defmodule Anime.LogFormatter do
  @moduledoc """
  Fail-closed, flat JSON formatter for the OTP stdout handler. Raw messages,
  reports, exceptions and arbitrary metadata are never formatted or inspected.
  """
  @version Mix.Project.config()[:version]
  @fallback ~s({"ts":"1970-01-01T00:00:00.000000Z","level":"error","message":"Log formatting failed safely","node":"unknown","app_version":"#{@version}","request_id":null}\n)
  @ids ~w(anime_id episode_id video_upload_id transaction_id comment_id)a
  @methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS CONNECT TRACE)
  @views ~w(AnimeWeb.AuthLive AnimeWeb.ProfileLive AnimeWeb.PlaceholderLive AnimeWeb.AdminIndexLive AnimeWeb.AdminLive AnimeWeb.ContentPlaceholderLive AnimeWeb.UsersLive AnimeWeb.UserActivityLive AnimeWeb.UserAdminLive AnimeWeb.RolesLive AnimeWeb.PermissionsLive AnimeWeb.MatrixLive)
  @actions ~w(login register request_reset reset home catalog genres blog donate feedback terms privacy overview settings bookmarks change index new blocked show)
  @events ~w(validate submit confirm revoke revoke_others preferences validate_nick validate_email validate_deletion change_nick change_email resend_email cancel_email delete_account filter page new edit cancel_edit save prepare cancel activity_filter change review reset select select_page prepare_bulk cancel_bulk confirm_bulk admin_locale retry_list)
  @workers ~w(Anime.Workers.Mail Anime.Workers.ExpireAccounts Anime.Workers.UnblockUsers Anime.Workers.DeleteAccounts)

  # OTP formatter callback. Do not let Logger's error fallback inspect the event.
  def format(event, _config) do
    meta = if is_map(event[:meta]), do: event.meta, else: %{}
    level = normalize_level(event[:level])
    own_message = Anime.Log.message(meta[:anime_event])

    record = %{
      ts: timestamp(meta[:time]),
      level: Atom.to_string(level),
      message: own_message || suppressed_message(meta),
      node: Atom.to_string(node()),
      app_version: @version,
      request_id: Anime.LogContext.valid_id(meta[:request_id])
    }

    allowed = if own_message, do: fields(meta[:anime_fields], level), else: %{}
    [Jason.encode!(Map.merge(record, allowed)), "\n"]
  rescue
    _ -> @fallback
  catch
    _, _ -> @fallback
  end

  # ExUnit.CaptureLog and Logger.default_formatter/1 use this older callback.
  # Its raw, already-translated message is deliberately ignored as well.
  def legacy_format(level, _message, _timestamp, metadata) do
    format(%{level: level, meta: Map.new(metadata)}, %{})
  rescue
    _ -> @fallback
  catch
    _, _ -> @fallback
  end

  def fields(input, level) when is_map(input) and not is_struct(input) do
    method = if input[:method] in @methods, do: input.method

    input
    |> Enum.reduce(%{}, fn
      {:method, _}, acc when not is_nil(method) ->
        Map.put(acc, :method, method)

      {:path, value}, acc when is_binary(value) ->
        Map.put(acc, :path, Anime.Log.safe_path(value, method || "GET"))

      {:status, value}, acc when is_integer(value) and value in 100..599 ->
        Map.put(acc, :status, value)

      {:duration_ms, value}, acc when is_number(value) and value >= 0 ->
        Map.put(acc, :duration_ms, value)

      {:live_view, value}, acc ->
        Map.put(acc, :live_view, label(value, @views))

      {:live_action, value}, acc when not is_nil(value) ->
        Map.put(acc, :live_action, label(value, @actions))

      {:live_event, value}, acc when not is_nil(value) ->
        Map.put(acc, :live_event, label(value, @events))

      {:socket_id, value}, acc when is_binary(value) ->
        if byte_size(value) <= 68 and Regex.match?(~r/\Aphx-[A-Za-z0-9_-]{16,64}\z/, value),
          do: Map.put(acc, :socket_id, value),
          else: acc

      {:oban_worker, value}, acc ->
        Map.put(acc, :oban_worker, label(value, @workers))

      {:oban_queue, value}, acc ->
        Map.put(acc, :oban_queue, label(value, ~w(mailers maintenance)))

      {key, value}, acc
      when key in [:oban_job_id, :oban_attempt] and is_integer(value) and value > 0 ->
        Map.put(acc, key, value)

      {:oban_duration_ms, value}, acc when is_number(value) and value >= 0 ->
        Map.put(acc, :oban_duration_ms, value)

      {:user_id, value}, acc
      when level in [:warning, :error] and is_integer(value) and value > 0 ->
        Map.put(acc, :user_id, value)

      {key, value}, acc when key in @ids and is_integer(value) and value > 0 ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  def fields(_, _), do: %{}

  defp label(value, allowed) when is_atom(value),
    do: label(value |> Atom.to_string() |> String.trim_leading("Elixir."), allowed)

  defp label(value, allowed), do: if(value in allowed, do: value, else: "[unknown]")

  defp timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value, :microsecond) do
      {:ok, date} -> DateTime.to_iso8601(date)
      _ -> timestamp(nil)
    end
  end

  defp timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp normalize_level(level) when level in [:debug, :info, :warning, :error], do: level
  defp normalize_level(:notice), do: :info
  defp normalize_level(_), do: :error

  defp suppressed_message(meta) do
    # Only compiler-supplied module/function atoms, never exception/report data.
    case meta[:mfa] do
      {module, function, arity}
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity in 0..255 ->
        source = "#{module}.#{function}/#{arity}"

        if byte_size(source) <= 200 and Regex.match?(~r/\A[A-Za-z0-9_.!?\/]+\z/, source),
          do: "Unstructured log suppressed (#{source})",
          else: "Unstructured log suppressed"

      _ ->
        "Unstructured log suppressed"
    end
  end
end
