defmodule Anime.ReleaseTest do
  use ExUnit.Case, async: true

  test "does not migrate through a running application" do
    assert_raise ArgumentError, ~r/separate release eval/, &Anime.Release.migrate/0
    assert_raise ArgumentError, ~r/separate release eval/, &Anime.Release.seed/0
    assert_raise ArgumentError, ~r/separate release eval/, &Anime.Release.storage_setup/0
  end

  test "rollback rejects other repos and invalid versions" do
    for args <- [[OtherRepo, 0], [Anime.Repo, -1], [Anime.Repo, "0"]] do
      assert_raise ArgumentError, fn -> apply(Anime.Release, :rollback, args) end
    end
  end

  test "migration URL errors never contain credentials" do
    for value <- [
          nil,
          "",
          "https://private:SECRET@example.com/db",
          "postgres://u:SECRET@host/db?unknown=1"
        ] do
      error = assert_raise ArgumentError, fn -> Anime.RuntimeConfig.migration_database!(value) end
      assert Exception.message(error) =~ "MIGRATION_DATABASE_URL"
      refute Exception.message(error) =~ "SECRET"
    end
  end

  test "valid migration URL keeps its SSL choice" do
    assert Anime.RuntimeConfig.migration_database!("postgres://u:p@localhost/db?ssl=true")
    assert Anime.RuntimeConfig.migration_database!("ecto://u:p@localhost/db?ssl=false") == false
    assert Anime.RuntimeConfig.migration_database!("ecto://u:p@localhost/db") == nil
  end
end
