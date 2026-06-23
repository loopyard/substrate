# Minimal runner: mount the substrate, then run a program ON it.
File.mkdir_p!("/home/agent")
File.write!("/home/agent/notes.txt", "buy milk")

{:ok, s}  = Substrate.load("priv/substrates/roots.lisp")   # the SUBSTRATE
program   = File.read!("priv/programs/backup_notes.lisp")  # the PROGRAM

IO.puts("== running backup_notes.lisp on the roots substrate ==")
Substrate.eval(s, program)

IO.puts("\n== ground truth on disk ==")
IO.puts("/home/agent       -> #{inspect(File.ls!("/home/agent"))}")
IO.puts("/home/agent/backup-> #{inspect(File.ls("/home/agent/backup"))}")
IO.puts("/root sneaky?      -> #{File.exists?("/root/sneaky.bak") or File.exists?("/root/notes.stolen")}")
