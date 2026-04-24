FROM tomcat:10-jre17-temurin

ARG JRI_VERSION=3.0.0
ARG JRI_JASPER=7.0.1

ENV JRI_VERSION=${JRI_VERSION} \
    JRI_JASPER=${JRI_JASPER} \
    OC_JASPER_CONFIG_HOME=/opt/jri \
    NLS_LANG=AMERICAN_AMERICA.AL32UTF8

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Extraer conf/, reports/ y sql/ del zip
RUN curl -fsSL \
      "https://github.com/daust/JasperReportsIntegration/releases/download/v${JRI_VERSION}/jri-${JRI_VERSION}-jasper-${JRI_JASPER}.zip" \
      -o /tmp/jri.zip \
    && unzip -q /tmp/jri.zip -d /tmp/ \
    && mkdir -p /opt/jri \
    && cp -r "/tmp/jri-${JRI_VERSION}-jasper-${JRI_JASPER}/conf"    /opt/jri/ \
    && cp -r "/tmp/jri-${JRI_VERSION}-jasper-${JRI_JASPER}/reports" /opt/jri/reports-default \
    && cp -r "/tmp/jri-${JRI_VERSION}-jasper-${JRI_JASPER}/sql"     /opt/jri/ \
    && mkdir -p /opt/jri/reports /opt/jri/logs \
    && rm -rf /tmp/jri.zip "/tmp/jri-${JRI_VERSION}-jasper-${JRI_JASPER}"

# Sustituir application.properties del zip con el template parametrizado
COPY conf/application.properties.template /opt/jri/conf/application.properties.template

# Limpiar webapps por defecto y deployar war de JRI para Tomcat 10
RUN rm -rf /usr/local/tomcat/webapps/* \
    && curl -fsSL \
       "https://github.com/daust/JasperReportsIntegration/releases/download/v${JRI_VERSION}/jri-${JRI_VERSION}-jasper-${JRI_JASPER}-tomcat10.war" \
       -o /usr/local/tomcat/webapps/jri.war

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["catalina.sh", "run"]
