defmodule Anime.RepoAfterCommitTest do
  use Anime.DataCase

  test "outside a transaction callbacks run immediately" do
    assert Repo.after_commit(fn -> send(self(), :committed) end) == :ok
    assert_received :committed
  end

  test "nested transactions defer callbacks until the outer commit, in order" do
    assert {:ok, :done} =
             Repo.transaction(fn ->
               Repo.after_commit(fn -> send(self(), {:committed, 1, Repo.in_transaction?()}) end)

               assert {:ok, :inner} =
                        Repo.transaction(fn _repo ->
                          Repo.after_commit(fn ->
                            send(self(), {:committed, 2, Repo.in_transaction?()})
                          end)

                          :inner
                        end)

               refute_received {:committed, _, _}
               :done
             end)

    assert_receive {:committed, 1, false}
    assert_receive {:committed, 2, false}
  end

  test "outer rollback discards callbacks queued by successful nested transactions" do
    assert {:error, :cancel} =
             Repo.transaction(fn ->
               Repo.transaction(fn -> Repo.after_commit(fn -> send(self(), :leaked) end) end)
               Repo.rollback(:cancel)
             end)

    assert {:ok, :next} = Repo.transaction(fn -> :next end)
    refute_received :leaked
  end

  test "exceptions discard callbacks and do not contaminate the next transaction" do
    assert_raise RuntimeError, "probe", fn ->
      Repo.transaction(fn ->
        Repo.after_commit(fn -> send(self(), :leaked) end)
        raise "probe"
      end)
    end

    assert {:ok, :next} = Repo.transaction(fn -> :next end)
    refute_received :leaked
  end

  test "Multi success commits notifications and Multi failure discards them" do
    queued =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:queued, fn repo, _ ->
        repo.after_commit(fn -> send(self(), :multi_committed) end)
        {:ok, :queued}
      end)

    assert {:error, :fail, :cancel, _} =
             Repo.transaction(Ecto.Multi.error(queued, :fail, :cancel))

    refute_received :multi_committed
    assert {:ok, %{queued: :queued}} = Repo.transaction(queued)
    assert_received :multi_committed
  end

  test "transact return semantics and callbacks that open another transaction are preserved" do
    assert {:error, :cancel} =
             Repo.transact(fn ->
               Repo.after_commit(fn -> send(self(), :leaked) end)
               {:error, :cancel}
             end)

    assert {:ok, :done} =
             Repo.transact(fn ->
               Repo.after_commit(fn ->
                 Repo.transaction(fn ->
                   Repo.after_commit(fn -> send(self(), :child_committed) end)
                 end)
               end)

               {:ok, :done}
             end)

    assert_received :child_committed
    refute_received :leaked
  end
end
