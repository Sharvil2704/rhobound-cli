# SPDX-License-Identifier: Apache-2.0
#
# The "browse" mix of Phase B: the OpenTelemetry Demo's own load generator, with only its browse_product task.
#
# It imports the shipped locustfile from the load generator's image (/usr/src/app/locustfile.py), so its
# OpenTelemetry tracing, its flagd client and the task itself are the shipped ones; only the choice of task differs.
# Every visit of the frontend is then GET /api/products/{id}, one shape of calls below it, which the CLI can model,
# where the shipped mix of nine tasks gives the frontend visits with different calls.
#
# A subclass of the shipped WebsiteUser would inherit all its tasks (Locust adds a base class's tasks to a
# subclass's), so this is a new HttpUser that borrows the task function. Locust finds the user classes among this
# module's names; the shipped module's own WebsiteUser is reached only as shipped.WebsiteUser, so it does not run.
#
# Used by run.sh through LOCUST_LOCUSTFILE=/rbv/locustfile_browse.py (a ConfigMap mounted at /rbv). The container's
# working folder stays /usr/src/app, where the shipped file opens people.json.
import sys

sys.path.insert(0, "/usr/src/app")

import locustfile as shipped  # noqa: E402  (the shipped file's tracing and flagd set-up run on import)
from locust import HttpUser, between  # noqa: E402


class BrowseProductUser(HttpUser):
    wait_time = between(1, 10)  # the shipped WebsiteUser's
    tasks = [shipped.WebsiteUser.browse_product]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.tracer = shipped.trace.get_tracer(shipped.__name__)

    def index(self):
        # not a task here (no @task): the shipped on_start calls it once per user
        shipped.WebsiteUser.index(self)

    def on_start(self):
        shipped.WebsiteUser.on_start(self)
