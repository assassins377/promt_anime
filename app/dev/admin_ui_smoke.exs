# Synthetic, local-only UI data. Never run against the development or production DB.
unless Mix.env() == :test, do: raise("Use MIX_ENV=test")
db_url = Application.fetch_env!(:anime, Anime.Repo) |> Keyword.fetch!(:url) |> URI.parse()

unless db_url.host == "127.0.0.1" && db_url.path == "/anime_ui_test",
  do: raise("UI smoke requires the isolated anime_ui_test database on loopback")

repo = Application.fetch_env!(:anime, Anime.Repo)
Application.put_env(:anime, Anime.Repo, Keyword.put(repo, :pool, DBConnection.ConnectionPool))
endpoint = Application.fetch_env!(:anime, AnimeWeb.Endpoint)
Application.put_env(:anime, AnimeWeb.Endpoint, Keyword.put(endpoint, :server, true))
{:ok, _} = Application.ensure_all_started(:anime)
Logger.configure(level: :warning)
{:ok, _} = Anime.Seeds.defaults()

alias Anime.{Repo, Accounts.User, Access.Role}

unless Repo.get_by(User, nick: "ui_admin") do
  actor = Anime.Fixtures.user(%{"nick" => "ui_admin", "email" => "ui-admin@example.test"})
  owner = Repo.get_by!(Role, code: "owner")
  actor |> Ecto.Changeset.change(role_id: owner.id) |> Repo.update!()
end

actor = Repo.get_by!(User, nick: "ui_admin")

for n <- 1..55 do
  unless Repo.get_by(User, nick: "ui_reader_#{n}") do
    attrs =
      Anime.Fixtures.attrs(%{
        "nick" => "ui_reader_#{n}",
        "email" => "ui-reader-#{n}@example.test"
      })

    {:ok, user} =
      Anime.Accounts.register(attrs, %{ip: "198.18.0.#{n}", user_agent: "Local UI fixture"})

    if rem(n, 7) == 0 do
      user
      |> Ecto.Changeset.change(
        status: :blocked,
        block_reason: "UI fixture",
        blocked_at: DateTime.utc_now(),
        blocked_by_id: actor.id
      )
      |> Repo.update!()
    end
  end
end

for {nick, role_code, forced} <- [
      {"ui_forced", "user", true},
      {"ui_editor", "content_editor", false}
    ] do
  unless Repo.get_by(User, nick: nick) do
    user = Anime.Fixtures.user(%{"nick" => nick, "email" => "#{nick}@example.test"})
    role = Repo.get_by!(Role, code: role_code)

    user
    |> Ecto.Changeset.change(role_id: role.id, must_change_password: forced)
    |> Repo.update!()
  end
end

IO.puts(
  "Synthetic admin UI: http://localhost:4002/login (ui_admin; password from Anime.Fixtures)"
)
