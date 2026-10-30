import boto3

def crear_vpc():
    # Crear cliente de EC2
    ec2 = boto3.client('ec2')

    # Crear la VPC
    vpc = ec2.create_vpc(CidrBlock='193.168.5.0/16')
    vpc_id = vpc['Vpc']['VpcId']
    print(f"✅ VPC creada con ID: {vpc_id}")

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
        Tags=[{'Key': 'Name', 'Value': 'MiVPC-Boto3'}]
    )

    print("🌐 DNS habilitado y etiqueta 'MiVPC-Boto3' asignada.")
    return vpc_id

def crear_subred(vpc_id):
    # Crear cliente de EC2
    ec2 = boto3.client('ec2')

    # Crear la subred
    subred = ec2.create_subnet(
        VpcId=vpc_id,
        CidrBlock='193.168.5.0/24',
        TagSpecifications=[
            {
                'ResourceType': 'subnet',
                'Tags': [{'Key': 'Name', 'Value': 'MiSubred-boto3'}]
            },
        ],

    )
    subred_id = subred['Subnet']['SubnetId']
    print(f"✅ Subred creada con ID: {subred_id}")

    return subred_id

def delete_all_ec2_instances() :
    ec2 = boto3.client('ec2')
    response = ec2.describe_instances()
    instances = [instance for reservation in response['Reservations'] for instance in reservation['Instances']]
    
    if not instances:
        print("No hay instancias EC2 para eliminar.")
        return

    instance_ids = [instance['InstanceId'] for instance in instances]
    print(f"Eliminando instancias: {instance_ids}")
    
    ec2.terminate_instances(InstanceIds=instance_ids)
    print("✅ Todas las instancias EC2 han sido eliminadas.")

if __name__ == "__main__":
    vpc_id = crear_vpc()
    subred_id = crear_subred(vpc_id)
    print(f"🚀 Proceso completado. ID de la VPC: {vpc_id}, ID de la subred: {subred_id}")