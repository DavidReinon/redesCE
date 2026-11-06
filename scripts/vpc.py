import boto3

AMI_ID = "ami-0d97d7f07b25dd693"

# Crear cliente de EC2
ec2 = boto3.client('ec2')

def crear_vpc():
    # Crear la VPC
    vpc = ec2.create_vpc(CidrBlock='193.168.0.0/16')
    vpc_id = vpc['Vpc']['VpcId']
    print(f"VPC creada con ID: {vpc_id}")

    # Habilitar DNS support
    ec2.modify_vpc_attribute(
        VpcId=vpc_id,
        EnableDnsSupport={'Value': True}
    )

    # Habilitar DNS hostnames
    ec2.modify_vpc_attribute(
        VpcId=vpc_id,
        EnableDnsHostnames={'Value': True}
    )

    # Etiquetar la VPC (opcional)
    ec2.create_tags(
        Resources=[vpc_id],
        Tags=[{'Key': 'Name', 'Value': 'MiVPC-drg-11'}]
    )

    print("🌐 DNS habilitado y etiqueta 'MiVPC-drg-11' asignada.")
    return vpc_id

def crear_internet_gateway(vpc_id):
    igw = ec2.create_internet_gateway(
        TagSpecifications=[
            {
                'ResourceType': 'internet-gateway',
                'Tags': [{'Key': 'Name', 'Value': 'MiIGW-drg-11'}]
            },
        ]
    )
    igw_id = igw['InternetGateway']['InternetGatewayId']

    ec2.attach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)
    print(f"Internet Gateway {igw_id} creado y asociado a la VPC.")

    return igw_id

def crear_subred(vpc_id):
    # Crear la subred
    subred = ec2.create_subnet(
        VpcId=vpc_id,
        CidrBlock='193.168.5.0/24',
        TagSpecifications=[
            {
                'ResourceType': 'subnet',
                'Tags': [{'Key': 'Name', 'Value': 'MiSubred-drg-11'}]
            },
        ],

    )
    subred_id = subred['Subnet']['SubnetId']
    print(f"Subred creada con ID: {subred_id}")

    return subred_id

def crear_tabla_enrutamiento(vpc_id, igw_id, subred_id):
    tabla = ec2.create_route_table(
        VpcId=vpc_id,
        TagSpecifications=[
            {
                'ResourceType': 'route-table',
                'Tags': [{'Key': 'Name', 'Value': 'MiTablaRutas-drg-11'}]
            },
        ]
    )
    tabla_id = tabla['RouteTable']['RouteTableId']

    ec2.create_route(
        RouteTableId=tabla_id,
        DestinationCidrBlock='0.0.0.0/0',
        GatewayId=igw_id
    )

    ec2.associate_route_table(RouteTableId=tabla_id, SubnetId=subred_id)
    print(f"Tabla de rutas {tabla_id} creada y asociada a la subred.")

    return tabla_id


def crear_security_group(vpc_id):
    # Crear el Security Group
    sg = ec2.create_security_group(
        GroupName='MiSG-SSH-drg-11',
        Description='Grupo de seguridad para permitir acceso SSH',
        VpcId=vpc_id
    )
    sg_id = sg['GroupId']
    print(f"Security Group creado con ID: {sg_id}")

    return sg_id


def permitir_ssh(sg_id):
    # Añadir regla de entrada para SSH (puerto 22)
    ec2.authorize_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=[
            {
                'IpProtocol': 'tcp',
                'FromPort': 22,
                'ToPort': 22,
                'IpRanges': [{'CidrIp': '0.0.0.0/0'}]
            },
        ],
        TagSpecifications=[
            {
                'ResourceType': 'security-group-rule',
                'Tags': [{'Key': 'Name', 'Value': 'MiRegla-SSH-drg-11'}]
            },
        ]
    )
    print("Regla SSH (puerto 22) añadida al Security Group.")


def crear_instancia(subred_id, sg_id):
    # Crear la instancia EC2 en la subred y con el Security Group creados.
    # Para asignar IP pública, la subred y el SG deben ir dentro de NetworkInterfaces.
    respuesta = ec2.run_instances(
        ImageId=AMI_ID,
        InstanceType='t2.micro',
        KeyName='vockey',
        MinCount=1,
        MaxCount=1,
        NetworkInterfaces=[
            {
                'DeviceIndex': 0,
                'SubnetId': subred_id,
                'Groups': [sg_id],
                'AssociatePublicIpAddress': True
            },
        ],
        TagSpecifications=[
            {
                'ResourceType': 'instance',
                'Tags': [{'Key': 'Name', 'Value': 'MiEC2-drg-11'}]
            },
        ]
    )
    instancia_id = respuesta['Instances'][0]['InstanceId']
    print(f"Instancia EC2 creada con ID: {instancia_id}")

    return instancia_id


if __name__ == "__main__":
    vpc_id = crear_vpc()
    subred_id = crear_subred(vpc_id)
    igw_id = crear_internet_gateway(vpc_id)
    tabla_id = crear_tabla_enrutamiento(vpc_id, igw_id, subred_id)
    sg_id = crear_security_group(vpc_id)
    permitir_ssh(sg_id)
    instancia_id = crear_instancia(subred_id, sg_id)
    print(
        "Proceso completado. "
        f"VPC: {vpc_id}, subred: {subred_id}, IGW: {igw_id}, "
        f"tabla de rutas: {tabla_id}, SG: {sg_id}, instancia: {instancia_id}"
    )