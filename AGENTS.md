# Development Guidelines
- build with scripts/build.sh & scripts/test.sh (test includes building within it), they include setting the env var DEVELOPMENT_TEAM=LS679A9VV4 for signing, and they only output on failure.
- write tests
- don't run test.sh too excessively as it does take >30 seconds, run it after groups of changes not after every change
