// stdout is a protocol channel in both modes (native messaging framing or
// MCP over stdio). Everything human-readable must go to stderr.
import { USAGE, parseMode } from "./mode";

function main(): void {
  const mode = parseMode(process.argv.slice(2));
  switch (mode) {
    case "host":
      process.stderr.write("cbb host: not implemented yet\n");
      process.exitCode = 1;
      return;
    case "mcp":
      process.stderr.write("cbb mcp: not implemented yet\n");
      process.exitCode = 1;
      return;
    case undefined:
      process.stderr.write(USAGE);
      process.exitCode = 2;
      return;
  }
}

main();
