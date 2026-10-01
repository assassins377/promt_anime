defmodule Anime.Storage.Setup do
  @moduledoc "Explicit bucket provisioning; never invoked at application startup."
  import SweetXml
  alias ExAws.S3
  @kinds ~w(ORIGINALS VIDEO PREVIEWS POSTERS AVATARS)

  def plan(env \\ System.get_env()) do
    names =
      Enum.map(@kinds, fn kind ->
        name = Map.get(env, "MINIO_BUCKET_" <> kind, "anime-" <> String.downcase(kind))

        unless is_binary(name) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/, name),
          do: raise(ArgumentError, "Invalid MINIO_BUCKET_#{kind}")

        name
      end)

    unless length(Enum.uniq(names)) == 5, do: raise(ArgumentError, "Bucket names must differ")
    names
  end

  def run(opts \\ []) do
    names = plan(Keyword.get(opts, :env, System.get_env()))
    request = Keyword.get(opts, :request, &ExAws.request(&1, retries: [max_attempts: 1]))
    region = Keyword.get(opts, :region, Application.get_env(:ex_aws, :region, "us-east-1"))

    # Check every existing bucket before any mutation. A 403 never means missing.
    states =
      Enum.map(names, fn name ->
        case call(request, S3.head_bucket(name)) do
          {:ok, _} ->
            unversioned!(request, name)
            {name, :existing}

          {:error, {:http_error, 404, _}} ->
            {name, :missing}

          _ ->
            fail!(name, "head_bucket")
        end
      end)

    Enum.each(states, fn {name, state} ->
      if state == :missing, do: ok!(request, S3.put_bucket(name, region), "create_bucket")
      unversioned!(request, name)

      case call(request, S3.delete_bucket_policy(name)) do
        {:ok, _} -> :ok
        error -> unless no_policy?(error), do: fail!(name, "delete_policy")
      end

      unless no_policy?(call(request, S3.get_bucket_policy(name))),
        do: fail!(name, "verify_private_policy")

      ok!(request, S3.put_bucket_lifecycle(name, rules()), "put_lifecycle")

      case call(request, S3.get_bucket_lifecycle(name)) do
        {:ok, %{body: body}} ->
          unless lifecycle_valid?(body), do: fail!(name, "verify_lifecycle")

        _ ->
          fail!(name, "get_lifecycle")
      end
    end)

    {:ok, names}
  end

  defp rules do
    [
      %{
        id: "exports-7d",
        enabled: true,
        filter: %{prefix: "exports/"},
        actions: %{expiration: %{trigger: {:days, 7}}}
      }
    ]
  end

  defp unversioned!(request, name) do
    valid =
      case call(request, S3.get_bucket_versioning(name)) do
        {:ok, %{body: body}} ->
          xml_check(body, fn doc ->
            xpath(doc, ~x"name(/*)"s) == "VersioningConfiguration" and
              xpath(doc, ~x"count(/*/*)"i) == 0
          end)

        _ ->
          false
      end

    unless valid, do: fail!(name, "require_unversioned_bucket")
  end

  defp no_policy?({:error, {:http_error, 404, %{body: body}}}) do
    xml_check(body, &(xpath(&1, ~x"/Error/Code/text()"s) == "NoSuchBucketPolicy"))
  end

  defp no_policy?(_), do: false

  defp lifecycle_valid?(body) do
    xml_check(body, fn doc ->
      entries = xpath(doc, ~x"/LifecycleConfiguration/Rule"l)

      signatures =
        Enum.map(entries, fn rule ->
          {xpath(rule, ~x"./ID/text()"s), xpath(rule, ~x"./Status/text()"s),
           xpath(rule, ~x"./Filter/Prefix/text()"s),
           xpath(rule, ~x"./AbortIncompleteMultipartUpload/DaysAfterInitiation/text()"s),
           xpath(rule, ~x"./Expiration/Days/text()"s)}
        end)

      Enum.sort(signatures) == [
        {"exports-7d", "Enabled", "exports/", "", "7"}
      ]
    end)
  end

  defp xml_check(body, check) when is_binary(body) and byte_size(body) <= 65_536 do
    body |> SweetXml.parse(dtd: :none, quiet: true) |> check.()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp xml_check(_, _), do: false

  defp ok!(request, operation, label) do
    case call(request, operation) do
      {:ok, _} -> :ok
      _ -> fail!(operation.bucket, label)
    end
  end

  defp call(request, operation) do
    request.(operation)
  rescue
    _ -> {:error, :request_failed}
  catch
    _, _ -> {:error, :request_failed}
  end

  defp fail!(bucket, operation), do: raise("Storage setup failed: #{bucket}: #{operation}")
end
