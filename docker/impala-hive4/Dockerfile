# ---------------------------------------------------------------------------
# MODIFIED BY: j.martinez.poblete@gmail.com (BigData-on-K8S warehouse profile)
# Custom image. Origin: apache/impala:4.5.3-<role> (upstream, unmodified base).
# Purpose: replaces org.apache.impala.compat.MetastoreShim in impala-frontend with the patched
# copy in src/ so Impala accepts tables from a Hive 4 metastore that leaves accessType unset.
#
#   docker buildx build --platform linux/amd64 --build-arg ROLE=catalogd \
#     -t jpoblete73/impala:4.5.3-catalogd-hive4 --push docker/impala-hive4
#   docker buildx build --platform linux/amd64 --build-arg ROLE=impalad_coord_exec \
#     -t jpoblete73/impala:4.5.3-impalad_coord_exec-hive4 --push docker/impala-hive4
# ---------------------------------------------------------------------------
ARG IMPALA_VERSION=4.5.3
ARG ROLE=impalad_coord_exec

FROM apache/impala:${IMPALA_VERSION}-${ROLE} AS upstream

FROM eclipse-temurin:8-jdk AS build
ARG IMPALA_VERSION
COPY --from=upstream /opt/impala/lib /impala-lib
COPY src /src
RUN mkdir /out \
 && javac -nowarn -source 8 -target 8 -cp '/impala-lib/*' -d /out \
      /src/org/apache/impala/compat/MetastoreShim.java \
 && cp /impala-lib/impala-frontend-${IMPALA_VERSION}-RELEASE.jar /frontend.jar \
 && cd /out && jar uf /frontend.jar org/apache/impala/compat/MetastoreShim*.class

FROM upstream
ARG IMPALA_VERSION
COPY --from=build --chown=impala /frontend.jar /opt/impala/lib/impala-frontend-${IMPALA_VERSION}-RELEASE.jar
