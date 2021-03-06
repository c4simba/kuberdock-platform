
# KuberDock - is a platform that allows users to run applications using Docker
# container images and create SaaS / PaaS based on these applications.
# Copyright (C) 2017 Cloud Linux INC
#
# This file is part of KuberDock.
#
# KuberDock is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# KuberDock is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with KuberDock; if not, see <http://www.gnu.org/licenses/>.

"""Add 'is_default' flag to kube types model

Revision ID: 28b23145af40
Revises: 56f9182bf415
Create Date: 2015-11-04 15:15:29.561256

"""

# revision identifiers, used by Alembic.
revision = '28b23145af40'
down_revision = '56f9182bf415'

from alembic import op
import sqlalchemy as sa
from sqlalchemy.orm import sessionmaker
from sqlalchemy.ext.declarative import declarative_base

Session = sessionmaker()
Base = declarative_base()

class Kube(Base):
    __tablename__ = 'kubes'
    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True, nullable=False)
    is_default = sa.Column(sa.Boolean, default=None, nullable=True, unique=True)


def upgrade():
    bind = op.get_bind()
    session = Session(bind=bind)
    ### commands auto generated by Alembic - please adjust! ###
    op.add_column('kubes', sa.Column('is_default', sa.Boolean(), nullable=True))
    op.create_unique_constraint(None, 'kubes', ['is_default'])
    ### end Alembic commands ###
    kube = session.query(Kube).filter(Kube.id >= 0).order_by(Kube.id).first()
    if kube is not None:
        kube.is_default = True
        session.commit()


def downgrade():
    ### commands auto generated by Alembic - please adjust! ###
    op.drop_constraint('kubes_is_default_key', 'kubes', type_='unique')
    op.drop_column('kubes', 'is_default')
    ### end Alembic commands ###
