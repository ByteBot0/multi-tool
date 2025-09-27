import curses
import os
import json
import sys

CONFIG_FILE = "tools-config.json"
TOOLS_DIR = "tools"

def load_config():
    if not os.path.exists(CONFIG_FILE):
        return {"tools": []}
    with open(CONFIG_FILE, "r") as f:
        return json.load(f)

def save_config(config):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=4)

def show_help(stdscr, tool_name):
    help_file = os.path.join(TOOLS_DIR, tool_name, "doc", "help.txt")
    if not os.path.exists(help_file):
        msg = f"No help available for {tool_name}"
        stdscr.clear()
        stdscr.addstr(0, 0, msg)
        stdscr.refresh()
        stdscr.getch()
        return

    with open(help_file, "r") as f:
        lines = f.readlines()

    h, w = stdscr.getmaxyx()
    win = curses.newwin(h, w, 0, 0)
    curses.curs_set(0)

    pos = 0
    while True:
        win.clear()
        for idx, line in enumerate(lines[pos:pos + h - 2]):
            try:
                win.addstr(idx, 0, line.strip())
            except curses.error:
                pass

        win.addstr(h - 1, 0, " ↑/↓ scroll | q to close ")
        win.refresh()

        key = win.getch()
        if key == curses.KEY_UP and pos > 0:
            pos -= 1
        elif key == curses.KEY_DOWN and pos < len(lines) - (h - 2):
            pos += 1
        elif key in (ord("q"), 27):  # q or Esc
            break

def draw_menu(stdscr, config):
    curses.curs_set(0)
    current_row, current_col = 0, 0
    max_row = len(config["tools"])  # plus NEXT at the end

    while True:
        stdscr.clear()
        h, w = stdscr.getmaxyx()


        for idx, tool in enumerate(config["tools"]):
            checkbox = "[x]" if tool.get("enabled", False) else "[ ]"
            toolname = f"{checkbox} {tool['name']}"

            # Tool column
            if idx == current_row and current_col == 0:
                stdscr.addstr(idx, 0, toolname, curses.A_REVERSE)
            else:
                stdscr.addstr(idx, 0, toolname)

            # Help column
            help_text = "help"
            if idx == current_row and current_col == 1:
                stdscr.addstr(idx, w // 2, help_text, curses.A_REVERSE)
            else:
                stdscr.addstr(idx, w // 2, help_text)

        # NEXT button
        next_text = "NEXT"
        if current_row == max_row:
            stdscr.addstr(max_row + 1, 0, next_text, curses.A_REVERSE)
        else:
            stdscr.addstr(max_row + 1, 0, next_text)

        stdscr.refresh()
        key = stdscr.getch()

        if key == curses.KEY_UP and current_row > 0:
            current_row -= 1
        elif key == curses.KEY_DOWN and current_row < max_row:
            current_row += 1
        elif key == curses.KEY_LEFT and current_col > 0:
            current_col -= 1
        elif key == curses.KEY_RIGHT and current_col < 1 and current_row < max_row:
            current_col += 1
        elif key in [curses.KEY_ENTER, 10, 13]:
            if current_row < max_row:
                if current_col == 0:
                    # Toggle tool
                    tool = config["tools"][current_row]
                    tool["enabled"] = not tool.get("enabled", False)
                    save_config(config)
                elif current_col == 1:
                    # Show help
                    tool = config["tools"][current_row]
                    show_help(stdscr, tool["name"])
            else:
                # NEXT pressed
                stdscr.clear()
                stdscr.addstr(0, 0, "OPTIONS menu coming soon...")
                stdscr.refresh()
                stdscr.getch()
                return
        elif key in [ord("q"), 27]:
            break

def main(stdscr):
    config = load_config()
    draw_menu(stdscr, config)

if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except ImportError:
        if sys.platform.startswith("win"):
            print("Windows users: install windows-curses with:")
            print("    pip install windows-curses")
        else:
            raise
