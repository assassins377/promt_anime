defmodule Anime.Audit do
  use Ecto.Schema

  schema "audit_logs" do
    field :occurred_at, :utc_datetime_usec
    field :user_id, :integer
    field :actor_label, :string
    field :role_code, :string
    field :ip, :string
    field :action, :string
    field :object_type, :string
    field :object_id, :string
    field :old_value, :map
    field :new_value, :map
    field :result, Ecto.Enum, values: [:success, :denied, :error]
    timestamps(type: :utc_datetime_usec)
  end

  def record(actor, action, object_type, id, result, meta \\ %{}) do
    # Audit retains the full decision; stdout receives only a fixed event and ID.
    # A rejected changeset or a missing record is not an authorization failure.
    reason = get_in(meta, [:new_value, :reason]) || get_in(meta, [:new_value, "reason"])

    if result == :denied && action in Anime.Access.Catalog.codes() &&
         reason in [
           nil,
           "forbidden",
           "protected_owner",
           "privilege_escalation",
           "self_action",
           "last_owner",
           "system_role",
           "cannot_grant",
           "self_permission_removal"
         ] do
      Anime.Log.emit(:access_denied, %{user_id: actor && actor.id})
      :telemetry.execute([:anime, :access, :denied], %{count: 1}, %{permission: action})
    end

    Anime.Repo.insert!(%__MODULE__{
      occurred_at: DateTime.utc_now(),
      user_id: actor && actor.id,
      actor_label: if(actor, do: actor.nick, else: Map.get(meta, :actor_label, "guest")),
      role_code: if(actor && Ecto.assoc_loaded?(actor.role), do: actor.role.code),
      action: action,
      object_type: object_type,
      object_id: if(id, do: to_string(id)),
      result: result,
      ip: Map.get(meta, :ip),
      old_value: Map.get(meta, :old_value),
      new_value: Map.get(meta, :new_value)
    })
  end
end
