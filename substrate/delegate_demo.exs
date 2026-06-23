# Substrate — the agent authors policy: attenuated delegation, readable rules,
# and the trusted-side audit log. An agent holding write access to TWO dirs
# carves a STRICTLY NARROWER child surface (one dir, tighter rate) and runs a
# sub-task inside it — and cannot widen its own authority. Run: mix run delegate_demo.exs
alias Substrate.Show

hr = fn t -> IO.puts("\n\e[1m\e[36m══ #{t}\e[0m") end
note = fn t -> IO.puts("\e[2m   #{t}\e[0m") end

run = fn s, src ->
  IO.puts("\e[33m   agent> #{String.trim(src)}\e[0m")
  res = Substrate.eval(s, src)
  case res do
    str when is_binary(str) -> IO.puts(str |> String.split("\n") |> Enum.map_join("\n", &("   " <> &1)))
    other -> IO.puts("   => #{Show.form(other)}")
  end
  res
end

# --- L0/L2: load the locked-fs manifest, reveal its rules to the agent ---
root = Path.join(System.tmp_dir!(), "delegate_demo")
File.rm_rf!(root)
for d <- ~w(downloads cache), do: File.mkdir_p!(Path.join(root, d))

{:ok, s} =
  Substrate.load("priv/manifests/fs_locked.lisp",
    credentials: %{fs_root: root, fs_allow: ["downloads", "cache"]},
    reveal_rules: true
  )

note.("parent may write to: downloads/  cache/   (jail root, agent can't name it: #{root})")

hr.("1. READABLE RULES — the agent reads the policy it operates under")
note.("the deny-if RULE is glossed for the agent; the VALUE (which dirs) stays vaulted")
run.(s, "(describe fs/write)")

hr.("2. THE PARENT ITSELF CAN WRITE BOTH DIRS")
run.(s, ~s|(fs/write :path "cache/parent.txt" :content "parent wrote this")|)

hr.("3. DELEGATE — the agent carves a NARROWER child and runs a sub-task in it")
note.("child gets fs/write, only downloads/, at a tighter 3/min — authored in Lisp by the agent")
run.(s, ~s"""
(let [child (grant :caps [fs/write] :fs_allow ["downloads"] :rate "3/min")]
  (as child
    (fs/write :path "downloads/from-child.txt" :content "written by the sub-agent")))
""")
note.("on disk: #{File.exists?(Path.join(root, "downloads/from-child.txt"))}")

hr.("4. THE CHILD CANNOT REACH WHAT THE PARENT KEPT BACK")
note.("parent can write cache/ — but it granted the child only downloads/")
run.(s, ~s"""
(let [child (grant :caps [fs/write] :fs_allow ["downloads"])]
  (as child (fs/write :path "cache/sneak.txt" :content "x")))
""")
note.("sneak on disk? #{File.exists?(Path.join(root, "cache/sneak.txt"))}  (false)")

hr.("5. THE AGENT CANNOT WIDEN ITS OWN AUTHORITY")
note.("grant can only narrow — asking for a dir outside the parent's allowlist is denied")
run.(s, ~s|(grant :caps [fs/write] :fs_allow ["secrets"])|)
run.(s, ~s|(grant :caps [http/get] :fs_allow ["downloads"])|)

hr.("6. AUDIT LOG — the trusted side saw every call (the agent can't read this)")
for e <- Substrate.audit(s) do
  {tag, reason} = e.outcome
  IO.puts("   ##{e.seq}  #{String.pad_trailing(e.cap, 12)} -> #{tag}#{if reason, do: "  (#{reason})", else: ""}")
end

IO.puts("\n\e[1m\e[32m✓ the agent authored policy in Lisp — and could only ever tighten it.\e[0m")
