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
  defdelegate mount(server, manifest_ast, opts), to: Server
  defdelegate revoke(server, name), to: Server
  defdelegate restore(server, name), to: Server
  defdelegate approve(server, handle), to: Server
  defdelegate deny(server, handle), to: Server

  @doc "Parse a manifest source string into AST ready for `mount/3`."
  def read_manifest(src), do: Reader.read_one(src)

  @doc """
  The harness entry point. Read the source, evaluate it against the live surface,
  return the resulting value. A fault inside the sandbox (unbound symbol, bad
  call) is caught and returned as `{:fault, message}` — it never escapes L2.
  """
  def eval(server, src) do
    forms = Reader.read_all(src)
    Eval.run(forms, server)
  rescue
    e in Error -> {:fault, e.message}
  catch
    :substrate_break -> nil
  end
end
