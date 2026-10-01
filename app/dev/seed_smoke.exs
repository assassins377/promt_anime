# Only invoked against the private cluster created by check_queue1_local.sh.
# Never uses caller-provided ADMIN_* values or creates a real account.
defmodule Queue1SeedSmoke do
  import Ecto.Query
  alias Anime.{Repo, Seeds}
  alias Anime.Access.{Catalog, Permission, Role}
  alias Anime.Accounts.User

  def run do
    true = Mix.env() == :test
    expected_dir = System.fetch_env!("QUEUE1_CHECK_DATA_DIR")
    true = Path.basename(expected_dir) == "data"
    check_dir = Path.dirname(expected_dir)
    true = Regex.match?(~r"\Aanime-queue1-check\.[A-Za-z0-9]{8}\z", Path.basename(check_dir))
    true = Path.dirname(check_dir) == System.get_env("QUEUE1_CHECK_ROOT", "/tmp")
    [[^expected_dir]] = Repo.query!("SHOW data_directory").rows
    [["anime_test"]] = Repo.query!("SELECT current_database()").rows
    0 = Repo.aggregate(User, :count)

    # Unique synthetic credentials; no secrets printed, no mail is sent.
    System.put_env("ADMIN_EMAIL", "queue1-owner@example.com")
    System.put_env("ADMIN_NICK", "queue1_owner")
    System.put_env("ADMIN_PASSWORD", "Q1!" <> Base.url_encode64(:crypto.strong_rand_bytes(24)))

    try do
      {:ok, :created} = Seeds.owner!()
      first = snapshot()
      {:ok, :already_exists} = Seeds.owner!()
      ^first = snapshot()
      5 = Repo.aggregate(Role, :count)
      99 = Repo.aggregate(Permission, :count)
      expected = Catalog.permissions() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      ^expected = Repo.all(from p in Permission, order_by: p.code, select: p.code)
      %User{must_change_password: true, email_confirmed_at: %DateTime{}} = Repo.one!(User)
      [["owner"]] = Repo.query!("SELECT r.code FROM users u JOIN roles r ON r.id=u.role_id").rows
      IO.puts("Seed twice: 1 synthetic owner, 5 roles, 99 exact permissions; rows unchanged")
    after
      for name <- ~w(ADMIN_EMAIL ADMIN_NICK ADMIN_PASSWORD), do: System.delete_env(name)
    end
  end

  defp snapshot do
    for table <- ~w(users roles permissions role_permissions settings audit_logs) do
      {table, Repo.query!("SELECT row_to_json(t) FROM #{table} t ORDER BY id").rows}
    end
  end
end

Queue1SeedSmoke.run()
