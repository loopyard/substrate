defmodule Substrate.Stdio do
  @moduledoc """
  L1 — the native stdout client. The one capability whose effect is *words to the
  operator* rather than bytes on disk or packets on a wire. It still runs inside
  the trust boundary and is never nameable from L2: the substrate's `bind` is
  stripped at the wall like every other.

  Talking to the console is an effect. It leaves the sandbox — it reaches a human
  on the other side of the membrane — so the agent does not get it for free; a
  substrate must *grant* it (see `priv/substrates/stdio.lisp`). When granted, a
  print is adjudicated and recorded in the audit like any `fs/write`.

  The `[agent]` prefix is stamped here, in trusted code, so the sandboxed side's
  output is always attributed and can never be forged to look like the harness's
  own framing.

  Returns `{:ok, %{printed: text}}`; the membrane maps that onto a `:done`.
  """

  def write(_ctx, %{text: text}) do
    line = to_string(text)
    IO.puts("    [agent] " <> line)
    {:ok, %{printed: line}}
  end
end
