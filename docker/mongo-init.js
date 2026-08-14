// Seeds the two rotating application users for local development.
//
// In Kubernetes these users are created by the rotator itself on its first run, so this
// script exists only so that `make up` gives a working stack immediately without waiting
// for a CronJob. Both users start with the same locally-generated password; the rotator
// diverges them from the first rotation onward.

const database = process.env.MONGO_APP_DATABASE;
const password = process.env.MONGO_APP_PASSWORD;

const appDb = db.getSiblingDB(database);

for (const username of ["app_a", "app_b"]) {
  appDb.createUser({
    user: username,
    pwd: password,
    roles: [{ role: "readWrite", db: database }],
  });
  print(`created user ${username} on ${database}`);
}
