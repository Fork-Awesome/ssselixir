defmodule Ssselixir.Repo.Migrations.CreatePortPasswords do
  use Ecto.Migration

  def change do
    create table(:port_passwords) do
      add :port, :integer
      add :password, :string

      timestamps()
    end
  end
end
