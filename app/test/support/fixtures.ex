defmodule Anime.Fixtures do
  alias Anime.{Accounts, Repo}

  def attrs(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "email" => "user#{n}@example.com",
        "nick" => "reader#{n}",
        "password" => "InitialExample123",
        "password_confirmation" => "InitialExample123",
        "consent" => "true"
      },
      overrides
    )
  end

  def user(overrides \\ %{}) do
    {:ok, u} = Accounts.register(attrs(overrides), meta())
    Repo.preload(u, :role)
  end

  def meta, do: %{ip: "127.0.0.1", user_agent: "ExUnit"}

  def role_user(code) do
    u = user()
    role = Repo.get_by!(Anime.Access.Role, code: code)

    u
    |> Ecto.Changeset.change(role_id: role.id)
    |> Repo.update!()
    |> Repo.preload(:role, force: true)
  end

  def login_conn(conn, user) do
    {:ok, {raw, _}} = Accounts.create_session(user, false, meta())
    Plug.Test.init_test_session(conn, user_token: raw)
  end
end
