import itertools
import sys
import threading
import time


class ProgressSpinner:
    def __init__(self, message: str, interval: float = 0.2) -> None:
        self.message = message
        self.interval = interval
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self, done_message: str | None = None) -> None:
        if self._thread is None:
            return
        self._stop_event.set()
        self._thread.join()
        self._thread = None
        clear_width = max(len(self.message) + 6, 80)
        sys.stdout.write("\r" + (" " * clear_width) + "\r")
        if done_message:
            print(done_message, flush=True)
        else:
            sys.stdout.flush()

    def _run(self) -> None:
        for frame in itertools.cycle("|/-\\"):
            if self._stop_event.is_set():
                break
            sys.stdout.write(f"\r{self.message} {frame}")
            sys.stdout.flush()
            time.sleep(self.interval)
