"""
AWS Cost Alerter Lambda Function

Monitors AWS costs and sends alerts via ntfy when costs exceed thresholds.
Optionally can trigger resource cleanup when costs exceed critical threshold.
"""

import json
import os
import urllib.request
import urllib.error
from datetime import datetime, timedelta
import boto3
from botocore.exceptions import ClientError


def get_current_month_costs():
    """Get the current month's AWS costs using Cost Explorer API."""
    ce_client = boto3.client('ce')
    
    # Get the first day of the current month
    today = datetime.utcnow()
    start_of_month = today.replace(day=1).strftime('%Y-%m-%d')
    end_date = (today + timedelta(days=1)).strftime('%Y-%m-%d')
    
    try:
        response = ce_client.get_cost_and_usage(
            TimePeriod={
                'Start': start_of_month,
                'End': end_date
            },
            Granularity='MONTHLY',
            Metrics=['UnblendedCost', 'UsageQuantity'],
            GroupBy=[
                {'Type': 'DIMENSION', 'Key': 'SERVICE'}
            ]
        )
        
        total_cost = 0.0
        service_breakdown = {}
        
        for result in response.get('ResultsByTime', []):
            for group in result.get('Groups', []):
                service_name = group['Keys'][0]
                cost = float(group['Metrics']['UnblendedCost']['Amount'])
                service_breakdown[service_name] = cost
                total_cost += cost
        
        return {
            'total_cost': round(total_cost, 2),
            'service_breakdown': service_breakdown,
            'currency': 'USD',
            'period': f"{start_of_month} to {end_date}"
        }
        
    except ClientError as e:
        print(f"Error fetching costs: {e}")
        raise


def get_forecasted_month_end_cost():
    """Get the forecasted cost for the end of the current month."""
    ce_client = boto3.client('ce')
    
    today = datetime.utcnow()
    # Start from tomorrow to get forecast
    start_date = (today + timedelta(days=1)).strftime('%Y-%m-%d')
    # End of current month
    if today.month == 12:
        end_of_month = today.replace(year=today.year + 1, month=1, day=1)
    else:
        end_of_month = today.replace(month=today.month + 1, day=1)
    end_date = end_of_month.strftime('%Y-%m-%d')
    
    try:
        response = ce_client.get_cost_forecast(
            TimePeriod={
                'Start': start_date,
                'End': end_date
            },
            Metric='UNBLENDED_COST',
            Granularity='MONTHLY'
        )
        
        forecast = float(response['Total']['Amount'])
        return round(forecast, 2)
        
    except ClientError as e:
        # Forecast might not be available if not enough data
        print(f"Could not get forecast: {e}")
        return None


def send_ntfy_alert(topic, title, message, priority='high', tags=None):
    """Send an alert via ntfy.sh."""
    ntfy_server = os.environ.get('NTFY_SERVER', 'https://ntfy.sh')
    ntfy_token = os.environ.get('NTFY_TOKEN', '')
    
    url = f"{ntfy_server}/{topic}"
    
    headers = {
        'Title': title,
        'Priority': priority,
        'Tags': ','.join(tags) if tags else 'warning,dollar'
    }
    
    if ntfy_token:
        headers['Authorization'] = f'Bearer {ntfy_token}'
    
    data = message.encode('utf-8')
    
    req = urllib.request.Request(url, data=data, headers=headers, method='POST')
    
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status == 200
    except urllib.error.URLError as e:
        print(f"Failed to send ntfy alert: {e}")
        return False


def list_active_resources():
    """List key active resources in the account for the nuke warning."""
    resources = []
    
    # Check EC2 instances
    try:
        ec2 = boto3.client('ec2')
        instances = ec2.describe_instances(
            Filters=[{'Name': 'instance-state-name', 'Values': ['running', 'pending']}]
        )
        instance_count = sum(len(r['Instances']) for r in instances['Reservations'])
        if instance_count > 0:
            resources.append(f"EC2 Instances: {instance_count}")
    except ClientError:
        pass
    
    # Check RDS instances
    try:
        rds = boto3.client('rds')
        dbs = rds.describe_db_instances()
        db_count = len(dbs['DBInstances'])
        if db_count > 0:
            resources.append(f"RDS Instances: {db_count}")
    except ClientError:
        pass
    
    # Check NAT Gateways
    try:
        ec2 = boto3.client('ec2')
        nat_gws = ec2.describe_nat_gateways(
            Filters=[{'Name': 'state', 'Values': ['available', 'pending']}]
        )
        nat_count = len(nat_gws['NatGateways'])
        if nat_count > 0:
            resources.append(f"NAT Gateways: {nat_count}")
    except ClientError:
        pass
    
    # Check Lambda functions
    try:
        lambda_client = boto3.client('lambda')
        functions = lambda_client.list_functions()
        func_count = len(functions['Functions'])
        if func_count > 0:
            resources.append(f"Lambda Functions: {func_count}")
    except ClientError:
        pass
    
    # Check S3 buckets
    try:
        s3 = boto3.client('s3')
        buckets = s3.list_buckets()
        bucket_count = len(buckets['Buckets'])
        if bucket_count > 0:
            resources.append(f"S3 Buckets: {bucket_count}")
    except ClientError:
        pass
    
    return resources


def trigger_nuke_warning(cost_info, critical_threshold):
    """Send a critical warning about potential resource nuking."""
    ntfy_topic = os.environ.get('NTFY_TOPIC', 'aws-cost-alerts')
    
    resources = list_active_resources()
    resource_list = '\n'.join(f"  - {r}" for r in resources) if resources else "  (Unable to list resources)"
    
    message = f"""CRITICAL COST ALERT!

Current AWS spending: ${cost_info['total_cost']} USD
Critical threshold: ${critical_threshold} USD
Period: {cost_info['period']}

Top services by cost:
{format_top_services(cost_info['service_breakdown'])}

Active resources that may be nuked:
{resource_list}

ACTION REQUIRED: Review and terminate unnecessary resources immediately!

To prevent automated nuking, reduce costs below ${critical_threshold} or adjust the threshold."""

    send_ntfy_alert(
        topic=ntfy_topic,
        title='CRITICAL: AWS Cost Emergency',
        message=message,
        priority='urgent',
        tags=['rotating_light', 'dollar', 'skull']
    )


def execute_resource_nuke():
    """
    Execute resource cleanup using aws-nuke or custom cleanup logic.
    
    CAUTION: This is a destructive operation!
    
    For safety, this function only performs the nuke if:
    1. ENABLE_AUTO_NUKE environment variable is set to 'true'
    2. NUKE_DRY_RUN is not set to 'true' (dry run mode)
    
    In production, consider:
    - Using aws-nuke with a proper config
    - Implementing a multi-step approval process
    - Only terminating specific resource types
    """
    enable_nuke = os.environ.get('ENABLE_AUTO_NUKE', 'false').lower() == 'true'
    dry_run = os.environ.get('NUKE_DRY_RUN', 'true').lower() == 'true'
    ntfy_topic = os.environ.get('NTFY_TOPIC', 'aws-cost-alerts')
    
    if not enable_nuke:
        message = """Auto-nuke is DISABLED.

To enable automatic resource cleanup, set ENABLE_AUTO_NUKE=true.

For now, please manually review and terminate resources."""
        
        send_ntfy_alert(
            topic=ntfy_topic,
            title='Nuke Skipped - Manual Action Required',
            message=message,
            priority='high',
            tags=['hand', 'warning']
        )
        return {'status': 'skipped', 'reason': 'auto_nuke_disabled'}
    
    if dry_run:
        # In dry run mode, just list what would be deleted
        resources = list_active_resources()
        message = f"""DRY RUN - Would terminate:

{chr(10).join(f'  - {r}' for r in resources)}

Set NUKE_DRY_RUN=false to actually terminate resources."""
        
        send_ntfy_alert(
            topic=ntfy_topic,
            title='Nuke DRY RUN',
            message=message,
            priority='high',
            tags=['test_tube', 'warning']
        )
        return {'status': 'dry_run', 'resources': resources}
    
    # ACTUAL NUKE EXECUTION
    # This performs targeted cleanup of expensive resources
    terminated = []
    errors = []
    
    # Stop EC2 instances (not terminate, for safety)
    try:
        ec2 = boto3.client('ec2')
        instances = ec2.describe_instances(
            Filters=[{'Name': 'instance-state-name', 'Values': ['running']}]
        )
        instance_ids = []
        for reservation in instances['Reservations']:
            for instance in reservation['Instances']:
                # Skip instances with termination protection
                instance_ids.append(instance['InstanceId'])
        
        if instance_ids:
            ec2.stop_instances(InstanceIds=instance_ids)
            terminated.append(f"Stopped {len(instance_ids)} EC2 instances")
    except ClientError as e:
        errors.append(f"EC2: {str(e)}")
    
    # Delete NAT Gateways (expensive!)
    try:
        ec2 = boto3.client('ec2')
        nat_gws = ec2.describe_nat_gateways(
            Filters=[{'Name': 'state', 'Values': ['available']}]
        )
        for nat in nat_gws['NatGateways']:
            ec2.delete_nat_gateway(NatGatewayId=nat['NatGatewayId'])
            terminated.append(f"Deleted NAT Gateway: {nat['NatGatewayId']}")
    except ClientError as e:
        errors.append(f"NAT Gateway: {str(e)}")
    
    # Stop RDS instances (not delete, for safety)
    try:
        rds = boto3.client('rds')
        dbs = rds.describe_db_instances()
        for db in dbs['DBInstances']:
            if db['DBInstanceStatus'] == 'available':
                try:
                    rds.stop_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'])
                    terminated.append(f"Stopped RDS: {db['DBInstanceIdentifier']}")
                except ClientError:
                    pass  # Some RDS types can't be stopped
    except ClientError as e:
        errors.append(f"RDS: {str(e)}")
    
    # Send summary
    message = f"""NUKE EXECUTED

Actions taken:
{chr(10).join(f'  - {t}' for t in terminated) if terminated else '  (none)'}

Errors:
{chr(10).join(f'  - {e}' for e in errors) if errors else '  (none)'}

Please verify the changes in your AWS console."""
    
    send_ntfy_alert(
        topic=ntfy_topic,
        title='Resource Nuke Complete',
        message=message,
        priority='urgent',
        tags=['skull', 'check']
    )
    
    return {'status': 'executed', 'terminated': terminated, 'errors': errors}


def format_top_services(service_breakdown, top_n=5):
    """Format the top N services by cost."""
    sorted_services = sorted(
        service_breakdown.items(),
        key=lambda x: x[1],
        reverse=True
    )[:top_n]
    
    lines = []
    for service, cost in sorted_services:
        if cost > 0.01:  # Only show services with meaningful cost
            lines.append(f"  - {service}: ${cost:.2f}")
    
    return '\n'.join(lines) if lines else "  (No significant costs yet)"


def lambda_handler(event, context):
    """
    Main Lambda handler for cost alerting.
    
    Environment Variables:
    - ALERT_THRESHOLD: Cost threshold in USD for alerts (default: 10)
    - CRITICAL_THRESHOLD: Cost threshold for critical alerts/nuke warning (default: 50)
    - NTFY_TOPIC: ntfy topic name (default: aws-cost-alerts)
    - NTFY_SERVER: ntfy server URL (default: https://ntfy.sh)
    - NTFY_TOKEN: Optional authentication token for ntfy
    - ENABLE_AUTO_NUKE: Set to 'true' to enable automatic resource cleanup
    - NUKE_DRY_RUN: Set to 'false' to actually terminate resources (default: true)
    """
    
    alert_threshold = float(os.environ.get('ALERT_THRESHOLD', '10'))
    critical_threshold = float(os.environ.get('CRITICAL_THRESHOLD', '50'))
    ntfy_topic = os.environ.get('NTFY_TOPIC', 'aws-cost-alerts')
    
    print(f"Cost Alerter running - Alert threshold: ${alert_threshold}, Critical: ${critical_threshold}")
    
    # Get current costs
    cost_info = get_current_month_costs()
    current_cost = cost_info['total_cost']
    
    print(f"Current month cost: ${current_cost}")
    
    # Get forecasted cost (optional)
    forecasted_cost = get_forecasted_month_end_cost()
    forecast_msg = f"\nForecasted month-end cost: ${forecasted_cost}" if forecasted_cost else ""
    
    response = {
        'statusCode': 200,
        'current_cost': current_cost,
        'alert_threshold': alert_threshold,
        'critical_threshold': critical_threshold,
        'forecasted_cost': forecasted_cost,
        'alert_sent': False,
        'nuke_triggered': False
    }
    
    # Check critical threshold first
    if current_cost >= critical_threshold:
        print(f"CRITICAL: Cost ${current_cost} exceeds critical threshold ${critical_threshold}")
        
        trigger_nuke_warning(cost_info, critical_threshold)
        
        # Execute nuke if enabled
        nuke_result = execute_resource_nuke()
        response['nuke_triggered'] = True
        response['nuke_result'] = nuke_result
        response['alert_sent'] = True
        
    # Check alert threshold
    elif current_cost >= alert_threshold:
        print(f"ALERT: Cost ${current_cost} exceeds threshold ${alert_threshold}")
        
        message = f"""AWS Cost Alert

Current spending: ${current_cost} USD
Alert threshold: ${alert_threshold} USD
Period: {cost_info['period']}{forecast_msg}

Top services by cost:
{format_top_services(cost_info['service_breakdown'])}

Review your AWS resources to control costs."""

        send_ntfy_alert(
            topic=ntfy_topic,
            title=f'AWS Cost Alert: ${current_cost}',
            message=message,
            priority='high',
            tags=['warning', 'dollar']
        )
        response['alert_sent'] = True
        
    else:
        print(f"Cost ${current_cost} is within threshold ${alert_threshold}")
        
        # Optionally send daily summary even when under threshold
        if os.environ.get('SEND_DAILY_SUMMARY', 'false').lower() == 'true':
            message = f"""AWS Daily Cost Summary

Current spending: ${current_cost} USD
Alert threshold: ${alert_threshold} USD{forecast_msg}

Top services:
{format_top_services(cost_info['service_breakdown'])}

All costs within limits."""

            send_ntfy_alert(
                topic=ntfy_topic,
                title=f'AWS Cost Summary: ${current_cost}',
                message=message,
                priority='low',
                tags=['chart_with_upwards_trend', 'white_check_mark']
            )
    
    return response
