from flask import Blueprint, request, current_app, jsonify
from . import route
from ..notifications.models import NotificationTemplate
from ..notifications.events import NotificationEvent
from ..core import db, check_permission
from . import APIError


bp = Blueprint('notifications', __name__, url_prefix='/notifications')


@route(bp, '/', methods=['GET'])
# @check_permission('get', 'users')
def get_list():
    return jsonify({
        'status': 'OK',
        'data': [n.to_dict() for n in NotificationTemplate.all()]})


@route(bp, '/<tid>/', methods=['GET'])
# @check_permission('get', 'users')
def get_template(tid):
    t = NotificationTemplate.filter_by(id=tid).first()
    if t:
        return jsonify({'status': True, 'data': t.to_dict()})
    raise APIError("Template {0} doesn't exists".format(tid), 404)


@route(bp, '/', methods=['POST'])
# @check_permission('create', 'users')
def create_item():
    data = request.json
    print data
    event = data['event']
    if NotificationTemplate.filter_by(event=data['event']).first():
        raise APIError('Conflict: Template with event "{0}" already '
                       'exists'.format(NotificationEvent.get_event_name(event)))
    try:
        t = NotificationTemplate.create(**data).save()
    except Exception, e:
        return jsonify({'status': 'Operation failed with ex({0})'.format(e)})
    return jsonify({'status': 'OK', 'data': t.to_dict()})


@route(bp, '/<tid>/', methods=['PUT'])
# @check_permission('edit', 'users')
def put_item(tid):
    t = NotificationTemplate.filter_by(id=tid).first()
    if t:
        data = request.json
        t.update(data)
        return jsonify({'status': 'OK'})
    raise APIError("Template {0} doesn't exists", 404)


@route(bp, '/<tid>/', methods=['DELETE'])
# @check_permission('delete', 'users')
def delete_item(tid):
    t = NotificationTemplate.filter_by(id=tid).first()
    if t:
        t.delete()
        return jsonify({'status': 'OK'})
    raise APIError("Template {0} doesn't exists", 404)