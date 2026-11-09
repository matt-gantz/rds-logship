FROM public.ecr.aws/lambda/python:3.12

RUN dnf -y install unixODBC \
    && curl -sSL https://packages.microsoft.com/config/rhel/9/prod.repo -o /etc/yum.repos.d/microsoft-prod.repo \
    && ACCEPT_EULA=Y dnf -y install msodbcsql18 mssql-tools18 \
    && dnf clean all

ENV PATH="${PATH}:/opt/mssql-tools18/bin"

COPY app.py ${LAMBDA_TASK_ROOT}

CMD ["app.handler"]

