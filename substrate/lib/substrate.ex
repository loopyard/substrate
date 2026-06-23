defmodule Substrate do
  @moduledoc """
  Substrate — an AI harness where the agent is given a *computer*, not a menu of
  tools: a Turing-complete, sandboxed, live-mutable machine whose I/O is
  capability-secured and whose blast radius is bounded by construction.

  This module is the public seam:

    * **Authoring (trusted, L0/L2):** `start_link/1`, `mount/3`, `revoke/2`,
      `restore/2`, `approve/2`, `deny/2` — the developer side of the wall.
    * **Harness (untrusted, L3):** `eval/2` — the *only* thing the agent ever
      touches. It hands in substrate-Lisp source and gets back a value (almost
      always a disposition). It cannot reach anything else.
  """

  alias Substrate.Server
  alias Substrate.Lisp.{Reader, Eval, Error}

  defdelegate start_link(opts), to: Server
  defdelegate mount(server, substrate_ast, opts), to: Server
  defdelegate revoke(server, name), to: Server
  defdelegate restore(server, name), to: Server
  defdelegate approve(server, handle), to: Server
  defdelegate deny(server, handle), to: Server
  defdelegate attenuate(server, narrowing), to: Server
  defdelegate audit(server), to: Server

  @doc "Parse a substrate source string into AST ready for `mount/3`."
  def read_substrate(src), do: Reader.read_one(src)

  @doc """
  Load one or more substrate files into a fresh running substrate — the artifact
  becomes the runtime. Each file's `resource`/`secret` declarations are resolved
  (env vars read on this trusted side) and bound into the vault; the agent
  attaches to the returned server and reaches only what the substrates exposed.

      {:ok, s} = Substrate.load("priv/substrates/github.lisp")
      {:ok, s} = Substrate.load(["fs_locked.lisp", "github.lisp"], reveal_rules: true)

  `opts` are passed to each `mount` (e.g. `:reveal_rules`, or `:credentials` to
  override/supplement what the file declares — the integrator's last word).
  Returns `{:ok, server}`.
  """
  def load(path_or_paths, opts \\ [])

  def load(paths, opts) when is_list(paths) do
    {:ok, server} = Server.start_link(name: Keyword.get(opts, :name))
    mount_opts = Keyword.drop(opts, [:name])

    Enum.each(paths, fn path ->
      :ok = Server.mount(server, path |> File.read!() |> read_substrate(), mount_opts)
    end)

    {:ok, server}
  end

  def load(path, opts) when is_binary(path), do: load([path], opts)

  @doc """
  The harness entry point. Read the source, evaluate it against the live surface,
  return the resulting value. A fault inside the sandbox (unbound symbol, bad
  call) is caught and returned as `{:fault, message}` — it never escapes L2.
  """
  def eval(server, src) do
    forms = Reader.read_all(src, atoms: :existing)
    Eval.run_guarded(forms, server)
  rescue
    e in Error -> {:fault, e.message}
  end
end
