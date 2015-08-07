require 'spec_helper'

RSpec.describe PostgresqlSelection do

  def update_sms_priorities
    SetMemberSubject.where(priority: nil).each_with_index do |sms, index|
      sms.update_column(:priority, index+1)
    end
  end

  shared_examples "select for incomplete_project" do
    let(:args) { {} }
    let(:sms_scope) do
      if ss_id = args[:subject_set_id]
        SetMemberSubject.where(subject_set_id: ss_id)
      else
        SetMemberSubject.all
      end
    end
    let(:unseen_count) do
      _seen_count = if ss_id = args[:subject_set_id]
        group_sms = SetMemberSubject.where(subject_set_id: ss_id)
        group_sms.where(subject_id: uss.subject_ids).count
      else
        seen_count
      end
      sms_scope.count - _seen_count
    end


    context "when a user has only seen a few subjects" do
      let(:seen_count) { 5 }
      let!(:uss) do
        subject_ids = sms_scope.sample(seen_count).map(&:subject_id)
        create(:user_seen_subject, user: user, subject_ids: subject_ids, workflow: workflow)
      end

      it 'should return an unseen subject' do
        expect(uss.subject_ids).to_not include(subject.select(**args.merge(limit: 1)).first)
      end

      it 'should no have duplicates' do
        result = subject.select(**args.merge(limit: 10))
        expect(result).to match_array(result.to_a.uniq)
      end

      it 'should always return the requested number of subjects up to the unseen limit' do
        unseen_count.times do |n|
          expect(subject.select(**args.merge(limit: n+1)).length).to eq(n+1)
        end
      end
    end

    context "when a user has seen most of the subjects" do
      let(:seen_count) { 20 }
      let!(:uss) do
        subject_ids = sms_scope.sample(seen_count).map(&:subject_id)
        create(:user_seen_subject, user: user, subject_ids: subject_ids, workflow: workflow)
      end

      it 'should return as many subjects as possible' do
        unseen_count.times do |n|
          results = subject.select(**args.merge(limit: n+unseen_count))
          expect(results.length).to eq(unseen_count)
        end
      end
    end
  end

  describe "#select" do
    let(:user) { User.first }
    let(:workflow) { Workflow.first }
    let(:sms) { SetMemberSubject.all }

    before(:all) do
      uploader = create(:user)
      created_workflow = create(:workflow_with_subject_sets)
      create_list(:subject, 25, project: created_workflow.project, uploader: uploader).each do |subject|
        create(:set_member_subject, subject: subject, subject_set: created_workflow.subject_sets.first)
      end
    end
    after(:all) do
      DatabaseCleaner.clean_with(:deletion)
    end

    describe "random selection" do
      subject { PostgresqlSelection.new(workflow, user) }

      it_behaves_like "select for incomplete_project"
    end

    context "grouped selection" do
      subject { PostgresqlSelection.new(workflow, user) }

      before(:each) do
        allow_any_instance_of(Workflow).to receive(:grouped).and_return(true)
      end

      it_behaves_like "select for incomplete_project" do
        let(:args) { {subject_set_id: workflow.subject_sets.first.id} }
      end

      it 'should only select subjects in the specified group' do
        create(:user_seen_subject,
               user: user,
               subject_ids: sms.sample(5).map(&:subject_id),
               workflow: workflow)
        set_id = workflow.subject_sets.first.id
        result_ids = subject.select(subject_set_id: set_id)
        sms_subject_ids = SetMemberSubject.where(id: result_ids).pluck(:subject_set_id)
        expect(sms_subject_ids).to all( eq(set_id) )
      end
    end

    describe "priority selection" do
      subject { PostgresqlSelection.new(workflow, user) }

      before(:each) do
        update_sms_priorities
        allow_any_instance_of(Workflow).to receive(:prioritized).and_return(true)
      end

      it_behaves_like "select for incomplete_project"

      it 'should select subjects in desc order of the priority field' do
        desc_priority = sms.order(priority: :desc).pluck(:id)
        result = subject.select(limit: desc_priority.size)
        expect(desc_priority).to eq(result)
      end

      context "with an inverted sort order param" do

        it 'should select subjects in inverted order of the priority field' do
          asc_priority = sms.order(priority: :asc).pluck(:id)
          result = subject.select(limit: asc_priority.size, order: :asc)
          expect(asc_priority).to eq(result)
        end
      end
    end

    describe "priority and grouped selection" do
      subject { PostgresqlSelection.new(workflow, user) }

      before(:each) do
        %i( prioritized grouped ).each do |method|
          allow_any_instance_of(Workflow).to receive(method).and_return(true)
        end
      end

      before(:all) do
        update_sms_priorities
        created_workflow = Workflow.first
        subject_set = created_workflow.subject_sets.last
        create_list(:subject, 12, project: created_workflow.project, uploader: User.first).each do |subject|
          create(:set_member_subject, :with_priorities, subject: subject, subject_set: subject_set)
        end
      end

      let(:subject_set_id) { SubjectSet.first.id }
      let(:sms) { SetMemberSubject.where(subject_set_id: subject_set_id) }

      it_behaves_like "select for incomplete_project"  do
        let(:args) { {subject_set_id: subject_set_id} }
      end

      it 'should only select subjects in the specified group' do
        result = subject.select(subject_set_id: subject_set_id)
        desc_priority = sms.limit(result.length).order(id: :desc).pluck(:id)
        expect(desc_priority).to eq(result)
      end

      context "with an inverted sort order param on the second set" do
        let(:subject_set_id) { SubjectSet.last.id }

        it 'should select subjects in inverted order of the priority field' do
          result = subject.select(subject_set_id: subject_set_id, order: :asc)
          asc_priority = sms.limit(result.length).order(id: :asc).pluck(:id)
          expect(asc_priority).to eq(result)
        end
      end
    end
  end
end
