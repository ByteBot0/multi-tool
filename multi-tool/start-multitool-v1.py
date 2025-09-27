import curses
import json
import os
import sys

CONFIG_PATH = os.path.join("tools-config.json")
TOOLS_DIR = "tools"

def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

def main(stdscr):
    curses.curs_set(0)
    stdscr.keypad(True)

    config = load_config()
    tools = config["tools"]
    selected = {tool["name"]: False for tool in tools}

    pos = 0
    focus = "tool"  # "tool", "help", or "next"

    while True:
        stdscr.clear()
        stdscr.addstr(0, 0, "TOOLS:")

        for idx, tool in enumerate(tools):
            # Build line: tool name + help
            tool_name = tool["name"]
            help_label = "help"

            # Determine highlight
            if pos == idx and focus == "tool":
                stdscr.addstr(idx + 2, 0, tool_name, curses.A_REVERSE)
                stdscr.addstr(idx + 2, len(tool_name) + 3, help_label)
            elif pos == idx and focus == "help":
                stdscr.addstr(idx + 2, 0, tool_name)
                stdscr.addstr(idx + 2, len(tool_name) + 3, help_label, curses.A_REVERSE)
            else:
                stdscr.addstr(idx + 2, 0, tool_name)
                stdscr.addstr(idx + 2, len(tool_name) + 3, help_label)

            # Mark selected with a star
            if selected[tool_name]:
                stdscr.addstr(idx + 2, len(tool_name) + 8, "*")

        # NEXT button
        next_y = len(tools) + 3
        if pos == len(tools) and focus == "next":
            stdscr.addstr(next_y, 0, "NEXT", curses.A_REVERSE)
        else:
            stdscr.addstr(next_y, 0, "NEXT")

        key = stdscr.getch()

        if key == curses.KEY_UP and pos > 0:
            pos -= 1
            focus = "tool"
        elif key == curses.KEY_DOWN and pos < len(tools):
            pos += 1
            focus = "tool" if pos < len(tools) else "next"
        elif key == curses.KEY_LEFT and focus == "help":
            focus = "tool"
        elif key == curses.KEY_RIGHT and pos < len(tools) and focus == "tool":
            focus = "help"
        elif key in (curses.KEY_ENTER, 10, 13):
            if pos == len(tools) and focus == "next":
                break  # Move to options screen later
            elif focus == "tool":
                tool_name = tools[pos]["name"]
                selected[tool_name] = not selected[tool_name]
            elif focus == "help":
                show_help(stdscr, tools[pos]["name"])

    stdscr.clear()
    stdscr.addstr(0, 0, f"Selected tools: {', '.join([t for t in selected if selected[t]])}")
    stdscr.refresh()
    stdscr.getch()

def show_help(stdscr, tool_name):
    help_path = os.path.join(TOOLS_DIR, tool_name, "doc", "help.txt")
    if not os.path.exists(help_path):
        lines = ["No help available."]
    else:
        with open(help_path) as f:
            lines = f.readlines()

    h, w = stdscr.getmaxyx()
    help_win = curses.newwin(h-4, w-4, 2, 2)
    help_win.keypad(True)

    top = 0
    while True:
        help_win.clear()
        for i, line in enumerate(lines[top:top+h-5]):
            help_win.addstr(i, 0, line.strip())
        help_win.box()
        help_win.refresh()

        key = help_win.getch()
        if key == curses.KEY_UP and top > 0:
            top -= 1
        elif key == curses.KEY_DOWN and top < len(lines) - 1:
            top += 1
        elif key in (ord('q'), 10, 13):  # q or Enter exits
            break

if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except curses.error:
        print("Error: curses not supported on this terminal.")
        if sys.platform == "win32":
            print("Try: pip install windows-curses")
        sys.exit(1)

